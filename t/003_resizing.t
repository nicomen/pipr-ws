use Test::More;
use strict;
use warnings;
use Data::Dumper;
use Image::Size;
use File::Temp qw/tempdir/;

use_ok 'Pipr::WS';
use Dancer::Test;

my $cache       = tempdir( 'pipr-cacheXXXX',       CLEANUP => 1, );
my $thumb_cache = tempdir( 'pipr-thumb_cacheXXXX', CLEANUP => 1, );

Pipr::WS->config->{'cache_dir'} = $cache;
Pipr::WS->config->{'plugins'}->{'Thumbnail'}->{'cache'} = $thumb_cache;

response_status_is ['GET' => '/foo'], 404, 'response status is 404 for /foo';
response_status_is ['GET' => '/resized'], 404, 'response status is 404 for /resized';
response_status_is ['GET' => '/resized/40x40'], 404, 'response status is 404 for /resized/40x40';
response_status_is ['GET' => '/test/resized/30x30/'], 404, 'response status is 404 for /test/resized/30x30/';
my $test_image_url = '/images/test.png';
my $test_image_path = "public$test_image_url";
response_status_is ['GET' => $test_image_url], 200, 'test image exists';
response_status_is ['GET' => "/test/resized/30x30/$test_image_path"], 200, "response status is 200 for /test/resized/30x30/$test_image_path";
response_status_is ['GET' => "/test/resized/30x30/non-existing-image"], 404, "non-existing image returns 404";
response_status_is ['GET' => "/test/resized/30x30/http://dghasdfguasdfhgiouasdhfguiohsdfg/non-existing-image"], 404, "non-existing remote image returns 404";

my $empty_image_path = "public/images/empty.jpg";
response_status_is ['GET' => "/test/resized/30x30/$empty_image_path"], 400, "response status is 400 for /test/resized/30x30/$empty_image_path";

my $image;

$image = dancer_response(GET => "/test/resized/30x30/$test_image_path")->content;
is_deeply [imgsize(\$image)], [30,30,'JPG'], 'Correct resized width/height (30x30)';

$image = dancer_response(GET => "/test/resized/100x30/$test_image_path")->content;
is_deeply [imgsize(\$image)], [100,30,'JPG'], 'Correct resized width/height (100x30)';

$image = dancer_response(GET => "/test/resized/30x/$test_image_path")->content;
is_deeply [imgsize(\$image)], [30,24,'JPG'], 'Correct resized width/height (30x(24))';

$image = dancer_response(GET => "/test/resized/x30/$test_image_path")->content;
is_deeply [imgsize(\$image)], [38,30,'JPG'], 'Correct resized width/height ((38)x30)';

response_status_is ['GET' => "/test/resized/30x30/https://www.google.com/images/srpr/logo3w.png"], 403, "not able to fetch illegal images";

Pipr::WS->config->{'sites'}->{'test2'} = {
  sizes => [ '30x30' ],
  allowed_targets => [ 'https://www.google.com/' ],
};

response_status_is ['GET' => "/test2/resized/30x30/https://www.google.com/images/srpr/logo3w.png"], 200, "SSL works";

Pipr::WS->config->{'sites'}->{'test3'} = {
  sizes => [ '30x30' ],
  allowed_targets => [ 'https://abcnyheter.drpublish.aptoma.no/' ],
};

response_status_is ['GET' => "/test3/resized/30x30/https://abcnyheter.drpublish.aptoma.no/out/images/article//2014/06/16/194406041/1/stor/VI__15__Bombingen_av_Victoria_terrasse.jpg"], 200, "SSL works";

Pipr::WS->config->{'sites'}->{'test4'} = {
  sizes => [ '30x30' ],
  allowed_targets => [ 'https://www.google.no' ],
};

response_status_is ['GET' => "/test4/resized/30x30/https://www.google.no/images/branding/googleg/1x/googleg_standard_color_128dp.png"], 200, "SSL works";

# TODO: patterns without / has to be checked as if they had a slash (against host), or else: https://foo.com matches https://foo.com@someother.server.com

map { warn $_->{message} if $_->{level} eq 'error'; } @{ &read_logs };

done_testing;
