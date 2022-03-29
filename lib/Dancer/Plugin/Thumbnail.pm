package Dancer::Plugin::Thumbnail;

use strict;
use warnings;

=head1 NAME

Dancer::Plugin::Thumbnail - Easy thumbnails creating with Dancer and GD

=cut

use feature 'switch';
use File::Path;
use GD::Image;
use JSON::Any;
use List::Util qw( min max );
use Object::Signature;
use POSIX 'strftime';
use PerlIO::gzip;
use Path::Tiny;

=head1 VERSION

Version 0.07

=cut

our $VERSION = '0.07';

=head1 SYNOPSIS

 use Dancer;
 use Dancer::Plugin::Thumbnail;

 # simple resize
 get '/resized/:width/:image' => sub {
     resize param('image') => { w => param 'width' };
 }

 # simple crop
 get '/cropped/:width/:image' => sub {
     crop param('image') => { w => param 'width' };
 }

 # more complex
 get '/thumb/:w/:h/:image' => sub {
     thumbnail param('image') => [
         crop   => { w => 200, h => 200, a => 'lt' },
         resize => { w => param('w'), h => param('h'), s => 'min' },
     ], { format => 'jpeg', quality => 90 };
 }


=head1 METHODS

=head2 thumbnail ( $file, \@operations, \%options )

Makes thumbnail image from original file by chain of graphic operations.
Image file name may be an absolute path or relative from config->{'public'}.
Each operation is a reference for two elements array. First element
is an operation name (currently supported 'resize' and 'crop') and second is
operation arguments as hash reference (described in appropriate operation
section).

After operations chain completed final image creates with supplied options:

=over

=item cache

Directory name for storing final results. Undefined setting (default) breaks
caching and isn't recommended for any serious production usage. Relative
cache directory will be prefixed with config->{'appdir'} automatically.
Cache path is generated from original file name, its modification time,
operations with arguments and an options. If you are worried about cache
garbage collecting you can create a simple cron job like:

 find /cache/path -type f -not -newerat '1 week ago' -delete

=item format

Specifies output image format. Supported formats are 'gif', 'jpeg' and 'png'.
Special format 'auto' (which is default) creates the same format as original
image has.

=item compression

PNG compression level. From '0' (no compression) to '9' (maximum).
Default is '-1' (default GD compression level for PNG creation).

=item quality

JPEG quality specifications. From '0' (the worse) to '100' (the best).
Default is 'undef' (default GD quality for JPEG creation).

=back

Defaults for these options can be specified in config.yml:

my_plugins:
     Thumbnail:
         cache: var/cache
         compression: 7
         quality: 50

=cut

sub status {}

sub thumbnail {
    my ( $c, $file, $opers, $opts ) = @_;

$DB::single = 1;
    # load settings
    my $conf = {};

    # create absolute path
    unless ($file) {
        status 404;
        return '404 Not Found';
    }

    # create an absolute path
    $file = $file
      unless $file =~ m{^/};

    # check for file existance and readabilty
    unless ( -f $file && -r _ ) {
        status 404;
        return '404 Not Found';
    }

    # try to get stat info
    my @stat = stat $file or do {
        status 404;
        return '404 Not Found';
    };

    my $headers = $opts->{headers};
    # prepare Last-Modified header
    my $lmod = strftime '%a, %d %b %Y %H:%M:%S GMT', gmtime $stat[9];
    my $etag = sprintf '%x-%x-%x', ($stat[1], $stat[9], $stat[7]);
    # if the file was modified less than one second before the request
    # it may be modified in a near future, so we return a weak etag
    $etag = "W/$etag" if $stat[9] == time - 1;

    # processing conditional GET
    if ( ( $headers->header('If-Modified-Since') || '' ) eq $lmod ) {
        return { file => $file, last_modified => $lmod, etag => $etag, status => 304 };
    }

    # target format & content-type
    my $fmt = $opts->{format} || $conf->{format} || 'auto';

    # target options
    my $compression = $fmt eq 'png' ? $opts->{compression} // $conf->{compression} // -1 : 0;
    my $quality =
      $fmt eq 'jpeg'
      ? (
        exists $opts->{quality}
        ? $opts->{quality}
        : $conf->{quality}
      )
      : undef;

    # try to resolve cache directory
    my $cache_dir = exists $opts->{cache} ? $opts->{cache} : $conf->{cache};

    if ($cache_dir) {

        # check for an absolute path of cache directory
        $cache_dir = $cache_dir
          unless $cache_dir =~ m{^/};

        # check for existance of cache directory
        unless ( -d $cache_dir && -w _ ) {
            $c->log->warn("no cache directory at '$cache_dir'");
            File::Path::make_path( $cache_dir ) or $c->log->error("Unable to create '$cache_dir'");
        }
    }

    # cache path components
    my ( $cache_key, @cache_hier, $cache_file );
    if ($cache_dir) {

        # key should include file, operations and calculated defaults
        $cache_key = Object::Signature::signature( [ $file, $stat[9], $opers, $quality, $compression ] );
        @cache_hier = map { substr $cache_key, $_->[0], $_->[1] }[ 0, 1 ], [ 1, 2 ];
        $cache_file = path $cache_dir, @cache_hier, $cache_key;

        # try to get cached version
        if ( -f $cache_file ) {
            return { file => $cache_file->stringify, type => 'image/jpeg', last_modified => $lmod, etag => $etag };
        }
    }

    my $src_img;

    eval {
      my $path = Path::Tiny->new($file);
      my $fh = $path->filehandle;
      my $magic;
      if (read($fh,$magic,4)) {
        if (my $type = GD::Image::_image_type($magic)) {
          seek($fh,0,0);
          my $method = "_newFrom${type}";
          $src_img = GD::Image->$method(\$fh);
        } else {
          $src_img = GD::Image->new($path->slurp({ binmode => ':gzip(autopop)' }));
        }
      }
    };

    if (!$src_img) {
        $c->log->error("can't load image '$file'");
        status 500;
        return '500 Internal Server Error';
    };
    # original sizes
    my ( $src_w, $src_h ) = $src_img->getBounds;

    # destination image and its serialized form
    my ( $dst_img, $dst_bytes );

    # trasformations loop
    for ( my $i = 0 ; $i < $#$opers ; $i += 2 ) {

        # next task and its arguments
        my ( $op, $args ) = @$opers[ $i, $i + 1 ];

        # target sizes
        my $dst_w = $args->{w} || $args->{width};
        my $dst_h = $args->{h} || $args->{height};

        if ($op eq 'resize') {
                my $scale_mode = $args->{s} || $args->{scale} || 'max';
                do {
                    $c->log->error("unknown scale mode '$scale_mode'");
                    status 500;
                    return '500 Internal Server Error';
                } unless grep { $_ eq $scale_mode } ('max', 'min', 'force');

                $scale_mode = 'max' if !( $dst_h && $dst_w );

                do {

                    # calculate scale
                    no strict 'refs';
                    my $scale = &{$scale_mode}(
                        grep { $_ } $dst_w && $src_w / $dst_w,
                        $dst_h && $src_h / $dst_h
                    );
                    $scale = max $scale, 1;

                    # recalculate target sizes
                    ( $dst_w, $dst_h ) =
                      map { sprintf '%.0f', $_ / $scale } $src_w, $src_h;
                } unless ( $scale_mode eq 'force' );

                # create new image
                $dst_img = GD::Image->new( $dst_w, $dst_h, 1 ) or do {
                    $c->log->error("can't create image for '$file'");
                    status 500;
                    return '500 Internal Server Error';
                };

                # resize!
                $dst_img->copyResampled( $src_img, 0, 0, 0, 0, $dst_w, $dst_h, $src_w, $src_h );
        } elsif ($op eq 'crop') {
                $dst_w = min $src_w, $dst_w || $src_w;
                $dst_h = min $src_h, $dst_h || $src_h;

                # anchors
                my ( $h_anchor, $v_anchor ) = ( $args->{a} || $args->{anchors} || 'cm' ) =~ /^([lcr])([tmb])$/
                  or do {
                    $c->log->error("invalid anchors: '$args->{ anchors }'");
                    status 500;
                    return '500 Internal Server Error';
                  };

                # create new image
                $dst_img = GD::Image->new( $dst_w, $dst_h, 1 ) or do {
                    $c->log->error("can't create image for '$file'");
                    status 500;
                    return '500 Internal Server Error';
                };

                # crop!
                $dst_img->copy(
                    $src_img, 0, 0,
                    sprintf( '%.0f',
                          $h_anchor eq 'l' ? 0
                        : $h_anchor eq 'c' ? ( $src_w - $dst_w ) / 2
                        :                    $src_w - $dst_w ),
                    sprintf( '%.0f',
                          $v_anchor eq 't' ? 0
                        : $v_anchor eq 'm' ? ( $src_h - $dst_h ) / 2
                        :                    $src_h - $dst_h ),
                    $dst_w, $dst_h
                );
       } else {
           $c->log->error("unknown operation '$op'");
           status 500;
           return '500 Internal Server Error';
       }

        # keep destination image as original
        ( $src_img, $src_w, $src_h ) = ( $dst_img, $dst_w, $dst_h );
    }

    # generate image
    if ($fmt eq 'gif') {
      $dst_bytes = $dst_img->$fmt;
    }
    elsif ($fmt eq 'jpeg') {
      $dst_bytes = $quality ? $dst_img->$fmt($quality) : $dst_img->$fmt;
    }
    elsif ($fmt eq 'png') {
      $dst_bytes = $dst_img->$fmt($compression);
    }
    else {
      $c->log->error("unknown format '$fmt'");
      status 500;
      return '500 Internal Server Error';
    }

    # store to cache (if requested)
    if ($cache_file) {

        # create cache subdirectories
        for (@cache_hier) {
            next if -d ( $cache_dir = path $cache_dir, $_ );
            mkdir $cache_dir or do {
                $c->log->error("can't create cache directory '$cache_dir'");
                status 500;
                return '500 Internal Server Error';
            };
        }
        path($cache_file)->spew_raw($dst_bytes);
    }
    $c->log->debug("Returning generated version: " . $cache_file->stringify);
    # send useful headers & content
    return { file => $cache_file->stringify, type => 'image/jpeg', last_modified => $lmod, etag => $etag };
}

=head2 crop ( $file, \%arguments, \%options )

This is shortcut (syntax sugar) fully equivalent to call:

thumbnail ( $file, [ crop => \%arguments ], \%options )

Arguments includes:

=over

=item w | width

Desired width (optional, default not to crop by horizontal).

=item h | height

Desired height (optional, default not to crop by vertical).

=item a | anchors

Two characters string which indicates desired fragment of original image.
First character can be one of 'l/c/r' (left/right/center), and second - 't/m/b'
(top/middle/bottom). Default is 'cm' (centered by horizontal and vertical).

=back

=cut

=head2 resize ( $file, \%arguments, \%options )

This is shortcut and fully equivalent to call:

thumbnail ( $file, [ resize => \%arguments ], \%options )

Arguments includes:

=over

=item w | width

Desired width (optional, default not to resize by horizontal).

=item h | height

Desired height (optional, default not to resize by vertical).

=item s | scale

The operation always keeps original image proportions.
Horizontal and vertical scales calculates separately and 'scale' argument
helps to select maximum or minimum from "canditate" values.
Argument can be 'min' or 'max' (which is default).

=back

=cut

=head1 AUTHOR

Oleg A. Mamontov, C<< <oleg at mamontov.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-dancer-plugin-thumbnail at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Dancer-Plugin-Thumbnail>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Dancer::Plugin::Thumbnail


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Dancer-Plugin-Thumbnail>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Dancer-Plugin-Thumbnail>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Dancer-Plugin-Thumbnail>

=item * Search CPAN

L<http://search.cpan.org/dist/Dancer-Plugin-Thumbnail/>

=back


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Oleg A. Mamontov.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1;

