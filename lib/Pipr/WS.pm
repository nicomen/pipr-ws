package Pipr::WS;
use v5.10;

use Mojolicious::Lite;
use Dancer::Plugin::Thumbnail;

use Data::Dumper;
use Encode qw/encode_utf8/;

use Path::Tiny qw/path/;
use File::Share ':all';
use File::Spec;
use File::Type;
use HTML::TreeBuilder;
use Image::Size;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use lib 'lib';
use Pipr::LWPx::ParanoidAgent;
use LWP::UserAgent::Cached;
use List::Util;
use Digest::MD5 qw(md5_hex);
use File::Spec;
use File::Path;
use Mojo::URL;
use Net::DNS::Resolver;
use PerlIO::gzip;
use POSIX 'strftime';
use Cwd;
use URI;
use URI::Escape;

our $VERSION = '18.0.0';

my $ua = Pipr::LWPx::ParanoidAgent->new(
      agent => 'Reisegiganten PiPr',
      ssl_opts => {
         verify_hostname => 0,
         SSL_verify_mode => SSL_VERIFY_NONE,
      },
);

my $local_ua = LWP::UserAgent->new();
$local_ua->protocols_allowed( ['file'] );

my $share_dir = path(eval { dist_dir('Pipr-WS') } || (app->home, 'share'));
plugin 'YamlConfig'     => { file => path($share_dir, 'config.yml'), class => 'YAML::XS' };

app->renderer->paths(["$share_dir/views"]);
plugin 'rg_tt_renderer' => { template_options => {
    ENCODING => 'UTF-8',
  }
};

app->renderer->default_handler('tt');

helper 'logger' => sub { app->log };
warn Dumper(app->config);
warn Dumper(app->renderer->paths);

helper 'site_config' => sub {
    my ($c, @args) = @_;
    my $site_config = $c->stash->{'site_config'};
    return $site_config if $site_config;
    die unless $site_config = $c->app->config->{sites}->{ $c->stash->{site} };
    return $c->stash->{site_config} = $site_config;
};

use File::Basename;
helper 'render_file' => sub {
  my $c        = shift;
  my %args     = @_;
  my $filepath = $args{filepath};

  unless ( -f $filepath && -r $filepath ) {
      $c->app->log->error("Cannot read file [$filepath]. error [$!]");
      return;
  }

  my $filename = $args{filename} || fileparse($filepath);
  my $status   = $args{status}   || 200;

  my $headers = Mojo::Headers->new();
  $headers->add( 'Content-Type',        'image/jpeg' );

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
  $c->res->content->asset($asset);
  return $c->rendered($status);
};

$ua->whitelisted_hosts( @{ app->config->{whitelisted_hosts} } );
$ua->timeout(app->config->{timeout});

get '/' => sub {
  my ($c) = shift;
  $c->render( 'index', sites => app->config->{sites}) if app->config->{environment} ne 'production';
};

# Proxy images
get '/:site/p/:url' => sub {
    my ($c) = @_;
    my ( $site, $url ) = ($c->stash->{site}, $c->stash->{url});

    # $url = get_url("$site/p");

    my $site_config = app->config->{sites}->{ $site };
    $site_config->{site} = $site;
    if (app->config->{restrict_targets}) {
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
    if ( ( header('If-Modified-Since') || '' ) eq $lmod ) {
        return $c->render( text => '', status => 304 );
    }

    open my $fh, '<:gzip(autopop)', $file or do {
        return $c->reply->exception("can't read cache file '$file'");
    };

    my $ft = File::Type->new();

    undef $/; # slurp
    # send useful headers & content
    my $type = $ft->mime_type(<$fh>);
    close $fh;
    header('Cache-Control' => 'public, max-age=86400');
    header('ETag' => $etag);
    header('Last-Modified' => $lmod);
    open $fh, '<:gzip(autopop)', $file or do {
        return $c->reply->exception("can't read cache file '$file'");
    };
    return scalar <$fh>;

  return send_file($file, system_path => 1, content_type => $type);
};

get '/:site/dims/*url' => sub {
    my ($c) = @_;
    my ( $site, $url ) = ($c->stash->{site}, $c->stash->{url});

    # $url = get_url("$site/dims");

    my $local_image = get_image_from_url($c, $url);
    my ( $width, $height, $type ) = Image::Size::imgsize($local_image);

    $c->render( json => { image => { type => lc $type, width => $width, height => $height } } );
};

# support uploadcare style
get '/:site/-/:cmd/:params/:param2/*url' => sub {
   my ($c) = @_;
   my ($site, $cmd, $params, $param2, $url ) = map { $c->stash($_) } qw/site cmd params param2 url/;

   # $url = get_url("$site/-/$cmd/$params/$param2");

   if ($cmd eq 'scale_crop' && $param2 eq 'center') {
       return gen_image($c, $site, 'scale_crop_centered', $params, $url);
   }
   return $c->render( text => "illegal command: '$cmd'", status => '401' );
};

get '/:site/:cmd/:params/*url' => sub {
    my ($c) = @_;
    my ($site, $cmd, $params, $url ) = map { $c->stash($_) } qw/site cmd params url/;

#    $url = get_url("$site/$cmd/$params");

    return gen_image($c, $site, $cmd, $params, $url);
};

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
    if ( app->config->{restrict_targets} ) {
        my $info = "'$url' with '$params'";
        $c->log->debug( "checking $info");
        return $c->render( text => "no matching targets: $info", status => 401 )
          if !List::Util::first { $url =~ m{ $_ }gmx; }
            @{ $site_config->{allowed_targets} }, keys %{ $site_config->{shortcuts} || {} };
        return $c->render( text => "no matching sizes: $info", status => 401 )
          if !List::Util::first { $format =~ m{\A \Q$_\E \z}gmx; }
            @{ $site_config->{sizes} };
    }

    my $local_image = get_image_from_url($c, $url);
    return $c->render( text => "unable to download picture: $url", status => 'not_found' )
      if !$local_image;

    my $thumb_cache = path(app->config->{plugins}->{Thumbnail}->{cache}, $site)->stringify;

    $c->res->headers->header('Cache-Control' => 'public, max-age=86400');

    my $switch = {
        'resized' => sub {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return resize $local_image => {
              w => $width, h => $height, s => 'force'
            },
            {
              format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7
            }
        },
        'scale_crop_centered' => sub {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail $local_image => [
                  resize => {
                    w => $width, h => $height, s => 'min'
                  },
                  crop => {
                    w => $width, h => $height, a => 'cm'
                  },
            ],
            {
              format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7
            };
        },
        'cropped' => sub  {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail $local_image => [
                crop => {
                    w => $width + $x, h => $height + $y, a => 'lt'
                },
                crop => {
                    w => $width, h => $height, a => 'rb'
                },
            ],
            {
              format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7
            };
        },
        'thumbnail' => sub {
            my ($local_image, $width, $height, $x, $y, $thumb_cache) = @_;
            return thumbnail $local_image => [
                crop => {
                    w => 200, h => 200, a => 'lt'
                },
                resize => {
                    w => $width, h => $height, s => 'min'
                },
            ],
            {
              format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7
            };
        },
        'default' => sub {
            my ($c) = @_;
            return;
        },
  };

  my $res;
  eval {
<<<<<<< HEAD
    $res = $switch->{$cmd} ? $switch->{$cmd}->($local_image, $width, $height, $x, $y, $thumb_cache) : $switch->{'default'}->();
    die $res if $res =~ /Internal Server Error/;
    1;
=======
      my $body = $switch->{$cmd} ? $switch->{$cmd}->($local_image, $width, $height, $x, $y, $thumb_cache) : $switch->{'default'}->();
      die $body if $body =~ /Internal Server Error/;

      $c->res->headers->header('Content-Type' => 'image/jpeg');
      return $c->render_file( filepath => $body );
>>>>>>> e5a2543 (Initial mojolicious port)
  } or do {
      return $c->render( text => 'Unable to load image: ' . substr($@,0,2000), status => 400 );
  };
  debug "Sending file: $res->{file} ($res->{type})";
  return send_file($res->{file}, system_path => 1, content_type => $res->{type});
};

sub get_image_from_url {
    my ($c, $url) = @_;

    my $local_image = download_url($c, $url);
    my $ft          = File::Type->new();

    return if !$local_image;
    return if !-e $local_image;

    return $local_image
      if ( $ft->checktype_filename($local_image) =~ m{ \A image }gmx );

    app->log->debug("fetching image from '$local_image'");

    my $res = $local_ua->get("file:$local_image");

    my $tree = HTML::TreeBuilder->new_from_content( $res->decoded_content );

    my $ele = $tree->find_by_attribute( 'property', 'og:image' );
    my $image_url = $ele && $ele->attr('content');

    if ( !$image_url ) {
        $ele = $tree->look_down(
            '_tag' => 'img',
            sub {
                app->log->debug("$url: " . $_[0]->as_HTML);
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
        app->log->debug("fetching: $image_url instead from web page");
        $local_image = download_url( $c, $image_url, $local_image, 1 );
    }

    return $local_image;
}

sub download_url {
    my ( $c, $url, $local_file, $ignore_cache ) = @_;

    $url =~ s/\?$//;

    app->log->debug("downloading url: $url");

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
        if ( app->config->{allow_local_access} ) {
            my $local_file = path( $share_dir, $url )->stringify;
            app->log->debug("locally accessing $local_file");
            return $local_file if $local_file;
        }
    }

    $local_file ||= File::Spec->catfile(
        (
            File::Spec->file_name_is_absolute( app->config->{'cache_dir'} )
            ? ()
            : app->config->{appdir}
        ),
        app->config->{'cache_dir'},
        $site_config->{site},
        _url2file($url)
    );

    File::Path::make_path( dirname($local_file) );

    app->log->debug('local_file: ' . $local_file);

    return $local_file if !$ignore_cache && -e $local_file;

    app->log->debug("fetching from the net... ($url)");

    my $res = eval { $ua->get($url, ':content_file' => $local_file); };
    die ("Error getting $url: (".(request->uri).")" . ($res ? $res->status_line : $@) . Dumper($site_config))
      unless ($res && $res->is_success);

    # Try fetching image from HTML page

    return (($res && $res->is_success) ? $local_file : ($res && $res->is_success));
}

sub get_url {
    my ($strip_prefix) = @_;

    my $request_uri = request->request_uri();
    $request_uri =~ s{ \A /? \Q$strip_prefix\E /? }{}gmx;

    # if we get an URL like: http://pipr.opentheweb.org/overblikk/resized/300x200/http://g.api.no/obscura/external/9E591A/100x510r/http%3A%2F%2Fnifs-cache.api.no%2Fnifs-static%2Fgfx%2Fspillere%2F100%2Fp1172.jpg
    # We want to re-escape the external URL in the URL (everything is unescaped on the way in)
    # NOT needed?
    #    $request_uri =~ s{ \A (.+) (http://.*) \z }{ $1 . URI::Escape::uri_escape($2)}ex;

    return $request_uri;
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
  File::Spec->catfile(@parts,$url);
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

app->start;

1;

=pod

=head1 AUTHOR

   Nicolas Mendoza <mendoza@pvv.ntnu.no>

=head1 ABSTRACT

   Picture Proxy/Provider/Presenter

=cut
