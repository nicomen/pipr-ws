#!/usr/bin/env perl

use Test::More;

use strict;
use warnings;

use Data::Dumper;
use Image::Size;
use File::Temp qw/tempdir/;

use Test::Mojo;
use Pipr::WS;

my %test_config = ();

my $cache       = tempdir( 'pipr-cacheXXXX',       CLEANUP => 1, );
my $thumb_cache = tempdir( 'pipr-thumb_cacheXXXX', CLEANUP => 1, );

my $t = Test::Mojo->new('Pipr::WS');
$t->app->config->{'allow_local_access'} = 1;
$t->app->config->{'cache_dir'} = $cache;
$t->app->config->{'plugins'}->{'Thumbnail'}->{'cache'} = $thumb_cache;
$t->get_ok('/foo')->status_is(404, 'response status is 404 for /foo');

my $test_image_url = '/images/test.png';
my $test_image_path = "public$test_image_url";
$t->get_ok($test_image_url)->status_is(200, 'test image exists');
$t->get_ok("/test/resized/30x30/$test_image_path")->status_is(200, "response status is 200 for /test/resized/30x30/$test_image_path");
$t->get_ok("/test/resized/30x30/non-existing-image")->status_is(404, "non-existing image returns 404");
$t->get_ok("/test/resized/30x30/http://dghasdfguasdfhgiouasdhfguiohsdfg/non-existing-image")->status_is(404, "non-existing remote image returns 404");

my $test_image_url_gz = '/images/test_gzipped.png.gz';
my $test_image_path_gz = "public$test_image_url_gz";
$t->get_ok($test_image_url_gz)->status_is(200, 'test image exists');
$t->get_ok("/test/resized/30x30/$test_image_path_gz")->status_is(200, "response status is 200 for /test/resized/30x30/$test_image_path_gz");

my $test_image_url_gz2 = '/images/test_hotel_gzipped';
my $test_image_path_gz2 = "public$test_image_url_gz2";
$t->get_ok($test_image_url_gz2)->status_is(200, "test image exists: $test_image_path_gz2");
$t->get_ok("/test/resized/30x30/$test_image_path_gz2")->status_is(200, "response status is 200 for /test/resized/30x30/$test_image_path_gz2");

my $empty_image_path = "public/images/empty.jpg";
$t->get_ok("/test/resized/30x30/$empty_image_path")->status_is(400, "response status is 400 for /test/resized/30x30/$empty_image_path");

my $image;

$image = $t->get_ok("/test/resized/30x30/$test_image_path")->tx->res->body;
is_deeply [imgsize(\$image)], [30,30,'JPG'], 'Correct resized width/height (30x30)';

$image = $t->get_ok("/test/resized/100x30/$test_image_path")->tx->res->body;
is_deeply [imgsize(\$image)], [100,30,'JPG'], 'Correct resized width/height (100x30)';

$image = $t->get_ok("/test/resized/30x/$test_image_path")->tx->res->body;
is_deeply [imgsize(\$image)], [30,24,'JPG'], 'Correct resized width/height (30x(24))';

$image = $t->get_ok("/test/resized/x30/$test_image_path")->tx->res->body;
is_deeply [imgsize(\$image)], [38,30,'JPG'], 'Correct resized width/height ((38)x30)';

$t->get_ok("/test/resized/30x30/https://www.google.com/images/srpr/logo3w.png")->status_is(403, "not able to fetch illegal images");

$t->app->config->{'sites'}->{'test2'} = {
  sizes => [ '30x30' ],
  allowed_targets => [ 'https://www.google.com/' ],
};

$t->get_ok("/test2/resized/30x30/https://www.google.com/images/srpr/logo3w.png")->status_is(200, "SSL works");

$t->app->config->{'sites'}->{'test3'} = {
  sizes => [ '30x30' ],
  allowed_targets => [ 'https://abcnyheter.drpublish.aptoma.no/' ],
};

$t->get_ok("/test3/resized/30x30/https://abcnyheter.drpublish.aptoma.no/out/images/article//2014/06/16/194406041/1/stor/VI__15__Bombingen_av_Victoria_terrasse.jpg")->status_is(200, "SSL works");

$t->app->config->{'sites'}->{'test4'} = {
  sizes => [ '30x30' ],
  allowed_targets => [ 'https://www.google.no' ],
};

$t->get_ok("/test4/resized/30x30/https://www.google.no/images/branding/googleg/1x/googleg_standard_color_128dp.png")->status_is(200, "SSL works");

# TODO: patterns without / has to be checked as if they had a slash (against host), or else: https://foo.com matches https://foo.com@someother.server.com

#map { warn $_->{message} if $_->{level} eq 'error'; } @{ &read_logs };

done_testing;
