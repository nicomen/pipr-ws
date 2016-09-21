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

Pipr::WS->config->{'sites'}->{'test5'} = {
    sizes => [ '30x30' ],
#    allowed_targets => [ 'https://www.google.no' ],
    allowed_targets => [ '.*' ],
    replacements => [ [ 'test-pattern*', 'https://www.google.no' ] ]
};


response_status_is ['GET' => "/test5/resized/30x30/test-pattern/images/branding/googleg/1x/googleg_standard_color_128dp.png"], 200, "replacements works";

map { warn $_->{message} if $_->{level} eq 'error'; } @{ &read_logs };

done_testing;
