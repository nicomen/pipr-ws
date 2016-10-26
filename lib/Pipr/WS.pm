package Pipr::WS;
use v5.10;

use Dancer;
use Dancer::Config;
use Dancer::Plugin::Thumbnail;

#use Dancer::Plugin::ConfigJFDI;
use Data::Dumper;
use Encode;
use File::Slurp;
use File::Share ':all';
use File::Spec;
use File::Type;
use HTML::TreeBuilder;
use Image::Size;
use IO::Socket::SSL qw( SSL_VERIFY_NONE );
use Startsiden::LWPx::ParanoidAgent;
use LWP::UserAgent::Cached;
use List::Util;
use Digest::MD5 qw(md5_hex);
use File::Spec;
use File::Path;
use Net::DNS::Resolver;
use POSIX 'strftime';
use Cwd;
use URI;
use URI::Escape;

our $VERSION = '16.38.1';

my $ua = Startsiden::LWPx::ParanoidAgent->new(
      agent => 'Reisegiganten PiPr',
      ssl_opts => {
         verify_hostname => 0,
         SSL_verify_mode => SSL_VERIFY_NONE,
      },
);


my $local_ua = LWP::UserAgent->new();
$local_ua->protocols_allowed( ['file'] );

set 'appdir' => eval { dist_dir('Pipr-WS') } || File::Spec->catdir(config->{appdir}, 'share');

set 'confdir' => File::Spec->catdir(config->{appdir});

set 'envdir'  => File::Spec->catdir(config->{appdir}, 'environments');
set 'public'  => File::Spec->catdir(config->{appdir}, 'public');
set 'views'   => File::Spec->catdir(config->{appdir}, 'views');

Dancer::Config::load();

$ua->whitelisted_hosts( @{ config->{whitelisted_hosts} } );
$ua->timeout(config->{timeout});

get '/' => sub {
    template 'index' => { sites => config->{sites} } if config->{environment} ne 'production';
};

# Proxy images
get '/*/p/**' => sub {
    my ( $site, $url ) = splat;

    $url = get_url("$site/p");

    my $site_config = config->{sites}->{ $site };
    $site_config->{site} = $site;
    if (config->{restrict_targets}) {
        return do { debug "illegal site: $site";   status 'not_found' } if ! $site_config;
    }
    var 'site_config' => $site_config;

    my $file = get_image_from_url($url);

    # try to get stat info
    my @stat = stat $file or do {
        status 404;
        return '404 Not Found';
    };

    # prepare Last-Modified header
    my $lmod = strftime '%a, %d %b %Y %H:%M:%S GMT', gmtime $stat[9];

    # processing conditional GET
    if ( ( header('If-Modified-Since') || '' ) eq $lmod ) {
        status 304;
        return;
    }

    open my $fh, '<:raw', $file or do {
        error "can't read cache file '$file'";
        status 500;
        return '500 Internal Server Error';
    };

    my $ft = File::Type->new();

    # send useful headers & content
    content_type $ft->mime_type($file);
    header('Cache-Control' => 'public, max-age=86400');
    header 'Last-Modified' => $lmod;
    undef $/; # slurp
    return scalar <$fh>;

};

get '/*/dims/**' => sub {
    my ( $site, $url ) = splat;

    $url = get_url("$site/dims");

    my $local_image = get_image_from_url($url);
    my ( $width, $height, $type ) = Image::Size::imgsize($local_image);

    content_type 'application/json';
    return to_json {
        image => { type => lc $type, width => $width, height => $height }
    };
};

# support uploadcare style
get '/*/-/*/*/*/**' => sub {
   my ($site, $cmd, $params, $param2, $url ) = splat;

   $url = get_url("$site/-/$cmd/$params/$param2");

   if ($cmd eq 'scale_crop' && $param2 eq 'center') {
       return gen_image($site, 'scale_crop_centered', $params, $url);
   }
   return do { debug 'illegal command'; status '401'; };
};

get '/*/*/*/**' => sub {
    my ( $site, $cmd, $params, $url ) = splat;

    $url = get_url("$site/$cmd/$params");

    return gen_image($site, $cmd, $params, $url);
};

sub gen_image {
    my ($site, $cmd, $params, $url) = @_;

    return do { debug 'no site set';    status 'not_found' } if !$site;
    return do { debug 'no command set'; status 'not_found' } if !$cmd;
    return do { debug 'no params set';  status 'not_found' } if !$params;
    return do { debug 'no url set';     status 'not_found' } if !$url;

    my $site_config = config->{sites}->{ $site };
    $site_config->{site} = $site;
    if (config->{restrict_targets}) {
      return do { debug "illegal site: $site";   status 'not_found' } if ! $site_config;
    }
    var 'site_config' => $site_config;

    my ( $format, $offset ) = split /,/, $params;
    my ( $x,      $y )      = split /x/, $offset || '0x0';
    my ( $width,  $height ) = split /x/, $format;

    if ( config->{restrict_targets} ) {
        debug "checking '$url' with '$params'";
        return do { debug 'no matching targets'; status 'forbidden' }
          if !List::Util::first { $url =~ m{ $_ }gmx; }
            @{ $site_config->{allowed_targets} }, keys %{ $site_config->{shortcuts} || {} };
        return do { debug 'no matching sizes'; status 'forbidden' }
          if !List::Util::first { $format =~ m{\A \Q$_\E \z}gmx; }
            @{ $site_config->{sizes} };
    }

    my $local_image = get_image_from_url($url);
    return do { debug "unable to download picture: $url"; status 'not_found' }
      if !$local_image;

    my $thumb_cache = File::Spec->catdir(config->{plugins}->{Thumbnail}->{cache}, $site);

    header('Cache-Control' => 'public, max-age=86400');

    given ($cmd) {
        when ('resized') {
            return resize $local_image => {
                w => $width, h => $height, s => 'force'
            },
            {
                format => 'jpeg', quality => '100', cache => $thumb_cache, compression => 7
            }
        }
        when ('scale_crop_centered') {
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
        }
        when ('cropped') {
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
        }
        when ('thumbnail') {
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
        }
        default {
            return do { debug 'illegal command'; status '401'; }
        }
    }
};

sub get_image_from_url {
    my ($url) = @_;

    my $local_image = download_url($url);
    my $ft          = File::Type->new();

    return if !$local_image;
    return if !-e $local_image;

    return $local_image
      if ( $ft->checktype_filename($local_image) =~ m{ \A image }gmx );

    debug "fetching image from '$local_image'";

    my $res = $local_ua->get("file:$local_image");

    my $tree = HTML::TreeBuilder->new_from_content( $res->decoded_content );

    my $ele = $tree->find_by_attribute( 'property', 'og:image' );
    my $image_url = $ele && $ele->attr('content');

    if ( !$image_url ) {
        $ele = $tree->look_down(
            '_tag' => 'img',
            sub {
                debug "$url: " . $_[0]->as_HTML;
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
        debug "fetching: $image_url instead from web page";
        $local_image = download_url( $image_url, $local_image, 1 );
    }

    return $local_image;
}

sub download_url {
    my ( $url, $local_file, $ignore_cache ) = @_;

    my $site_config = var 'site_config';

    debug "downloading url: $url";

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
        if ( config->{allow_local_access} ) {
            my $local_file = File::Spec->catfile( config->{appdir}, $url );
            debug "locally accessing $local_file";
            return $local_file if $local_file;
        }
    }

    $local_file ||= File::Spec->catfile(
        (
            File::Spec->file_name_is_absolute( config->{'cache_dir'} )
            ? ()
            : config->{appdir}
        ),
        config->{'cache_dir'},
        $site_config->{site},
        _url2file($url)
    );

    File::Path::make_path( dirname($local_file) );

    debug 'local_file: ' . $local_file;

    return $local_file if !$ignore_cache && -e $local_file;

    debug "fetching from the net... ($url)";

    my $res = eval { $ua->get($url, ':content_file' => $local_file); };
    debug "Error getting $url: (".(request->uri).")" . ($res ? $res->status_line : $@) . Dumper($site_config)
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

true;

=pod

=head1 AUTHOR

   Nicolas Mendoza <mendoza@pvv.ntnu.no>

=head1 ABSTRACT

   Picture Proxy/Provider/Presenter

=cut
