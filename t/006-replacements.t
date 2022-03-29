#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Pipr::WS;

use Data::Dumper;
use Image::Size;
use File::Temp qw/tempdir/;

my $cache       = tempdir( 'pipr-cacheXXXX',       CLEANUP => 1, );
my $thumb_cache = tempdir( 'pipr-thumb_cacheXXXX', CLEANUP => 1, );

my $t = Test::Mojo->new('Pipr::WS');

$t->app->config->{'cache_dir'} = $cache;
$t->app->config->{'my_plugins'}->{'Thumbnail'}->{'cache'} = $thumb_cache;

$t->app->config->{'sites'}->{'test5'} = {
    sizes => [ '30x30' ],
#    allowed_targets => [ 'https://www.google.no' ],
    allowed_targets => [ '.*' ],
    replacements => [ [ 'test-pattern*', 'https://www.google.no' ] ]
};

$t->get_ok("/test5/resized/30x30/test-pattern/images/branding/googleg/1x/googleg_standard_color_128dp.png")->status_is(200, "replacements works");

done_testing;
