#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Mojo::Plack;
use Pipr::WS;

use Data::Dumper;
use Image::Size;
use File::Temp qw/tempdir/;

my $cache       = tempdir( 'pipr-cacheXXXX',       CLEANUP => 1, );
my $thumb_cache = tempdir( 'pipr-thumb_cacheXXXX', CLEANUP => 1, );

Pipr::WS->config->{'cache_dir'} = $cache;
Pipr::WS->config->{'plugins'}->{'Thumbnail'}->{'cache'} = $thumb_cache;

Pipr::WS->config->{'sites'}->{'test5'} = {
    sizes => [ '30x30' ],
#    allowed_targets => [ 'https://www.google.no' ],
    allowed_targets => [ '.*' ],
    replacements => [ [ 'test-pattern*', 'https://www.google.no' ] ]
};

my $t = Test::Mojo::Plack->new('Pipr::WS');
$t->get_ok("/test5/resized/30x30/test-pattern/images/branding/googleg/1x/googleg_standard_color_128dp.png")->status_is(200, "replacements works");

done_testing;
