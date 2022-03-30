package Pipr::WS;
use v5.10;

use Mojo::Base 'Mojolicious';
use Mojo::Log;
use Dancer::Plugin::Thumbnail;

use Data::Dumper;
use Encode qw/encode_utf8/;

use Path::Tiny qw/path/;
use File::Share 'dist_dir';
use File::Type;
use HTML::TreeBuilder;
use Image::Size;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use lib 'lib';
use Pipr::LWPx::ParanoidAgent;
use LWP::UserAgent::Cached;
use List::Util;
use Digest::MD5 qw(md5_hex);
use Mojo::URL;
use Net::DNS::Resolver;
use PerlIO::gzip;
use POSIX 'strftime';
use URI;

our $VERSION = '18.0.0';

my $max_age = 3 * 86400;

sub startup {
  my ($self) = @_;

  $self->plugin('Systemd');

  my $share_dir = path(eval { dist_dir('Pipr-WS') } || ($self->home, 'share'));
  $self->plugin('YamlConfig' => { file => path($share_dir, 'config.yml'), class => 'YAML::XS' });

  $self->log( Mojo::Log->new( path => $self->config->{logfile}, level => $self->config->{loglevel} ) ) if $self->mode eq 'production';

  $self->renderer->paths(["$share_dir/views"]);
  $self->plugin('tt_renderer' => { template_options => {
      ENCODING => 'UTF-8',
    }
  });
  $self->renderer->default_handler('tt');

  $self->static->paths(["$share_dir/public"]);
  $self->helper('share_dir' => sub { $share_dir });
  $self->helper('site_config' => sub {
    my ($c, @args) = @_;
    my $site = $c->stash->{site};
    my $site_config = $c->stash->{'site_config'};
    return $site_config if $site_config;
    die unless $site_config = $self->config->{sites}->{ $site };
    return $c->stash->{site_config} = $site_config;
  });
  $self->helper('allow_local_access' => sub {
    my $c = shift;
    $c->app->mode ne 'production' && $c->config->{allow_local_access};
  });


  $self->helper('render_file' => sub {
    my $c        = shift;
    my %args     = @_;
    my $filepath = $args{filepath};

    return $c->rendered($args{status}) if ($args{status} // '') eq '304';

    unless ( -f $filepath && -r $filepath ) {
      $c->app->log->error("Cannot read file [$filepath]. error [$!]");
      return;
    }

    my $filename     = $args{filename}     || path($filepath)->basename;
    my $status       = $args{status}       || 200;
    my $content_type = $args{content_type} || 'image/jpeg';

    my $headers = $args{headers} // Mojo::Headers->new();
    $headers->add( 'Content-Type', $content_type );

    # Asset
    my $asset = Mojo::Asset::File->new( path => $filepath );

    # Range
    # Partially based on Mojolicious::Static
    my $size = ( stat $filepath )[7];
    if ( my $range = $c->req->headers->range ) {

      my $start = 0;
      my $end = $size - 1 >= 0 ? $size - 1 : 0;

      # Check range
      if ( $range =~ m/^bytes=(\d+)-(\d+)?/ && $1 <= $end ) {
          $start = $1;
          $end = $2 if defined $2 && $2 <= $end;

          $status = 206;
          $headers->add( 'Content-Length' => $end - $start + 1 );
          $headers->add( 'Content-Range'  => "bytes $start-$end/$size" );
      }

      # Not satisfiable
      else {
          return $c->rendered(416);
      }

      # Set range for asset
      $asset->start_range($start)->end_range($end);
    }
    else {
      $headers->add( 'Content-Length' => $size );
    }

    $c->res->content->headers($headers);

    # Stream content directly from file
    $c->res->content->asset($asset) unless $c->req->method eq 'HEAD';
    return $c->rendered($status);
  });

  $self->helper( ua => sub {
    my $c = shift;
    my $ua = Pipr::LWPx::ParanoidAgent->new(
      agent => 'Reisegiganten PiPr',
      ssl_opts => {
         verify_hostname => 0,
         SSL_verify_mode => SSL_VERIFY_NONE,
      },
    );
    $ua->whitelisted_hosts( @{ $self->config->{whitelisted_hosts} } );
    $ua->timeout($c->stash('refresh') ? '180' : $self->config->{timeout});
    $ua;
  });

  $self->helper( local_ua => sub {
    my $local_ua = LWP::UserAgent->new();
    $local_ua->protocols_allowed( ['file'] );
    $local_ua;
  });

  $self->hook(before_dispatch => sub  {
    my $c = shift;
    my $refresh = $c->req->url->query->param('refresh');
    if ($refresh) {
      $c->stash( 'refresh' => $refresh );
      $c->req->url->query->remove('refresh');
    }
    if ($c->req->method eq 'PATCH') {
      $c->stash( 'refresh' => 1 );
    } elsif ($c->req->method eq 'DELETE') {
      $c->stash( 'refresh' => 2 );
    }
  });
  $self->setup_routes;
}

sub setup_routes {
  my $self = shift;

  my $r = $self->routes;

  $r->get('/' => sub {
    my ($c) = shift;
    return $c->render( 'index', sites => $c->config->{sites}) if ($c->app->mode ne 'production');
    return $c->render( text => 'Picture Provider/Processor');
  });

  # Proxy images
  $r->any('/:site/p/*url' => sub {
    my ($c) = @_;
    my ( $site, $url ) = ($c->stash->{site}, $c->stash->{url});

    $url = Mojo::URL->new($url)->query( $c->req->url->query );

    my $site_config = $self->config->{sites}->{ $site };
    if ($self->config->{restrict_targets}) {
      return $c->render( text => "illegal site: $site", status => 404 ) if ! $site_config;
    }

    my $file = get_image_from_url($c,$url);

    # try to get stat info
    my @stat = stat $file or do {
        return $c->reply->not_found;
    };

    # prepare Last-Modified header
    my $lmod = strftime '%a, %d %b %Y %H:%M:%S GMT', gmtime $stat[9];
    my $etag = sprintf '%x-%x-%x', ($stat[1], $stat[9], $stat[7]);
    # if the file was modified less than one second before the request
    # it may be modified in a near future, so we return a weak etag
    $etag = "W/$etag" if $stat[9] == time - 1;

    # processing conditional GET
    if ( ( $c->req->headers->header('If-Modified-Since') || '' ) eq $lmod ) {
        return $c->render( text => '', status => 304 );
    }

    open my $fh, '<:gzip(autopop)', $file or do {
        return $c->reply->exception("can't read cache file '$file'");
    };

    my $ft = File::Type->new();

    my $content_type = 'application/octet-stream';
    # reads in 16k of selected handle, or returns undef on failure
    # then checks contents
    my $pos = tell $fh;
    if ($pos != -1) {
      if (seek $fh, 0, Fcntl::SEEK_SET()) {
        if(read $fh, my $data, 16*1024) {
          seek $fh, $pos, Fcntl::SEEK_SET();
          $content_type = $ft->mime_type($data);
        }
      }
    }
    close($fh);

    # send useful headers & content
    $c->res->headers->header('Cache-Control' => 'public, max-age=' . $max_age);
    $c->res->headers->header('ETag' => $etag);
    $c->res->headers->header('Last-Modified' => $lmod);

    return $c->render_file( filepath => $file, content_type => $content_type, headers => $c->res->headers );
  });

  $r->get('/:site/dims/*url' => sub {
    my ($c) = @_;
    my ( $site, $url ) = ($c->stash->{site}, $c->stash->{url});

    $url = Mojo::URL->new($url)->query( $c->req->url->query );

    my $local_image = get_image_from_url($c, $url);
    my ( $width, $height, $type ) = Image::Size::imgsize($local_image);

    $c->render( json => { image => { type => lc $type, width => $width, height => $height } } );
  });

  # support uploadcare style
  $r->any('/:site/-/:cmd/:params/:param2/*url' => sub {
    my ($c) = @_;
    my ($site, $cmd, $params, $param2, $url ) = map { $c->stash($_) } qw/site cmd params param2 url/;

    $url = Mojo::URL->new($url)->query( $c->req->url->query );

    if ($cmd eq 'scale_crop' && $param2 eq 'center') {
       return gen_image($c, $site, 'scale_crop_centered', $params, $url);
    }
    return $c->render( text => "illegal command: '$cmd'", status => '401' );
  });

  $r->any('/:site/:cmd/:params/*url' => sub {
    my ($c) = @_;
    my ($site, $cmd, $params, $url ) = map { $c->stash($_) } qw/site cmd params url/;

    $url = Mojo::URL->new($url)->query( $c->req->url->query );

    $c->app->log->debug("Executing: $site, $cmd, $params, $url");

    return gen_image($c, $site, $cmd, $params, $url);
  });

}

sub gen_image {
    my ($c, $site, $cmd, $params, $url) = @_;

    return $c->render( text => 'no site set', status => 404 ) if !$site;
    return $c->render( text => 'no command set', status => 404 ) if !$cmd;
    return $c->render( text => 'no params set',  status => 404 ) if !$params;
    return $c->render( text => 'no url set',     status => 404 ) if !$url;

    my ( $format, $offset ) = split /,/, $params;
    my ( $x,      $y )      = split /x/, $offset || '0x0';
    my ( $width,  $height ) = split /x/, $format;

    my $site_config = $c->site_config;
    if ( $c->app->config->{restrict_targets} ) {
        my $info = "'$url' with '$params'";
        $c->app->log->debug( "checking $info");
        return $c->render( text => "no matching targets: $info", status => 403 )
          if !List::Util::first { $url =~ m{ $_ }gmx; }
            @{ $site_config->{allowed_targets} }, keys %{ $site_config->{shortcuts} || {} };
        return $c->render( text => "no matching sizes: $info", status => 403 )
          if !List::Util::first { $format =~ m{\A \Q$_\E \z}gmx; }
            @{ $site_config->{sizes} };
    }

    my $local_image = get_image_from_url($c, $url);
    return $c->render( text => "unable to download picture: $url", status => 404 )
      if !$local_image;

    my $thumb_cache = path($c->app->config->{my_plugins}->{Thumbnail}->{cache}, $site)->stringify;

    my $headers = $c->req->headers;
    my $opts = {
      format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7, headers => $headers, refresh => $c->stash('refresh'),
    };
    my $switch = {
        'resized' => sub {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail($c, $local_image => [
              resize => {
                w => $width, h => $height, s => 'force'
              }
            ],
            $opts,
            );
        },
        'scale_crop_centered' => sub {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail($c, $local_image => [
                  resize => {
                    w => $width, h => $height, s => 'min'
                  },
                  crop => {
                    w => $width, h => $height, a => 'cm'
                  },
            ],
            $opts,
            );
        },
        'cropped' => sub  {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail($c, $local_image => [
                crop => {
                    w => $width + $x, h => $height + $y, a => 'lt'
                },
                crop => {
                    w => $width, h => $height, a => 'rb'
                },
            ],
            $opts,
            );
        },
        'thumbnail' => sub {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail($c, $local_image => [
                crop => {
                    w => 200, h => 200, a => 'lt'
                },
                resize => {
                    w => $width, h => $height, s => 'min'
                },
            ],
            $opts,
            );
        },
        'default' => sub {
            my ($c) = @_;
            return;
        },
  };

  my $res;
  eval {
    $res = $switch->{$cmd} ? $switch->{$cmd}->($local_image, $width, $height, $x, $y, $thumb_cache) : $switch->{'default'}->();
    die $res if $res =~ /Internal Server Error/;
    $c->res->headers->header('Cache-Control' => 'public, max-age=' . $max_age);
    $c->res->headers->header('ETag' => $res->{etag});
    $c->res->headers->header('Last-Modified' => $res->{last_modified});
    $c->res->headers->header('X-Pipr-ThumbCache' => $res->{from_cache} ? 'HIT' : 'MISS');
    return $c->render_file( filepath => $res->{file}, headers => $c->res->headers );
    1;
  } or do {
      return $c->render( text => 'Unable to load image: ' . substr($@,0,2000), status => 400 );
  };

};

sub get_image_from_url {
    my ($c, $url) = @_;

    my $local_image = download_url($c, $url, undef, ($c->stash('refresh') // 0) > 1);
    my $ft          = File::Type->new();

    return if !$local_image;
    return if !-e $local_image;

    return $local_image
      if ( $ft->checktype_filename($local_image) =~ m{ \A image }gmx );

    $c->app->log->debug("fetching image from '$local_image'");
    my $res = $c->local_ua->get("file:$local_image");

    return $local_image if $res->headers->content_type =~ m{ \A image }gmx;

    my $tree = HTML::TreeBuilder->new_from_content( $res->decoded_content );

    my $ele = $tree->find_by_attribute( 'property', 'og:image' );
    my $image_url = $ele && $ele->attr('content');

    if ( !$image_url ) {
        $ele = $tree->look_down(
            '_tag' => 'img',
            sub {
                $c->app->log->debug("$url: " . $_[0]->as_HTML);
                ( $url =~ m{ dn\.no | nettavisen.no }gmx
                      && defined $_[0]->attr('title') )
                  || ( $url =~ m{ nrk\.no }gmx && $_[0]->attr('longdesc') );
            }
        );
        $image_url = $ele && $ele->attr('src');
    }

    if ($image_url) {
        my $u = URI->new_abs( $image_url, $url );
        $image_url = $u->canonical;
        $c->app->log->debug("fetching: $image_url instead from web page");
        $local_image = download_url( $c, $image_url, $local_image, 1 );
    }

    return $local_image;
}

sub download_url {
    my ( $c, $url, $local_file, $ignore_cache ) = @_;

    $url = ref $url ? $url->to_string : $url;

    $url =~ s/\?$//;

    $c->res->headers->header('X-Pipr-Cache', 'HIT');

    $c->app->log->debug("downloading url: $url");

    my $site_config = $c->site_config;

    for my $path (keys %{$site_config->{shortcuts} || {}}) {
        if ($url =~ s{ \A /? $path }{}gmx) {
            my $target = expand_macros($site_config->{shortcuts}->{$path}, request->headers->{host});
            $url = sprintf $target, ($url);
            last;
        }
    }

    for my $repl (@{ $site_config->{replacements} || [] }) {
        $url =~ s/$repl->[0]/$repl->[1]/;
    }

    $url =~ s{^(https?):/(?:[^/])}{$1/}mx;

    if ($url !~ m{ \A (https?|ftp)}gmx) {
        if ( $c->allow_local_access ) {
            my $local_file = path( $c->share_dir, $url )->stringify;
            $c->app->log->debug("locally accessing $local_file");
            return $local_file if $local_file;
        }
    }

    my $cache_dir = $c->app->config->{'cache_dir'};
    $local_file ||= path(
        ( $cache_dir && path( $cache_dir )->is_absolute ? $cache_dir : path($c->app->home, $cache_dir) ),
        $c->stash->{site},
        _url2file($url)
    )->stringify;

    my $dir_name = path( $local_file )->parent;
    $dir_name->mkpath;

    $c->app->log->debug('local_file: ' . $local_file);

    return $local_file if !$ignore_cache && -e $local_file;

    $c->app->log->debug("fetching from the net... ($url)");

    $c->res->headers->header('X-Pipr-Cache', 'MISS');

    my $res = eval { $c->ua->get($url, ':content_file' => $local_file); };
    if ($res && $res->is_success) {
      return $local_file;
    }

    $c->app->log->error("Error getting $url: (".($c->req->url).")" . ($res ? $res->status_line : $@) . Dumper($site_config));
    return ($res && $res->is_success);
}

sub _url2file {
  my ($url) = @_;

  $url = Mojo::URL->new($url);
  my $q = $url->query->to_hash;
  $url->query( map { ( $_ => $q->{$_} ) } sort keys %{ $q || {} } );
  $url = $url->to_string;

  $url =~ s{^https?://}{}; # treat https and http as the same file to save some disk cache

  my $md5 = md5_hex(encode_utf8($url));
  my @parts = ( $md5 =~ m/^(.)(..)/ );
  $url =~ s/\?(.*)/md5_hex($1)/e;
  $url =~ s/[^A-Za-z0-9_\-\.=?,()\[\]\$^:]/_/gmx;
  path(@parts,$url)->stringify;
}

sub expand_macros {
    my ($str, $host) = @_;

    my $map = {
      qa  => 'kua',
      dev => 'dev',
      kua => 'kua',
    };

    $host =~ m{ \A (?:(dev|kua|qa)[\.-])pipr }gmx;
    my $env_subdomain = $1 && $map->{$1} || 'www';
    $str =~ s{%ENV_SUBDOMAIN%}{$env_subdomain}gmx;

    return $str;
}

*thumbnail = \&Dancer::Plugin::Thumbnail::thumbnail;

1;

=pod

=head1 AUTHOR

   Nicolas Mendoza <mendoza@pvv.ntnu.no>

=head1 ABSTRACT

   Picture Proxy/Provider/Presenter

=cut
