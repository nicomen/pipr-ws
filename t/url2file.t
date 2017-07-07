#!/usr/bin/env perl

use Test::More;

use Pipr::WS;

my %tests = (
    'http://foo.com/bar?a=1&b=2&a=3' => 'c/78/http:__foo.com_bar0b1bd652ebbdf8159b280c804ac05ccc',
    'http://foo.com/bar?b=2&a=1&a=3' => 'c/78/http:__foo.com_bar0b1bd652ebbdf8159b280c804ac05ccc',

    'http://foo.com/bar?b=2&a=1'     => '5/64/http:__foo.com_bared04c91cf6f6ab5a01a31c0295c5da34',
    'http://foo.com/bar?a=1&b=2'     => '5/64/http:__foo.com_bared04c91cf6f6ab5a01a31c0295c5da34',
);

while (my ($in, $exp) = each %tests) {
    is(Pipr::WS::_url2file($in), $exp, "$in => $exp");
}

done_testing;
