#!/usr/bin/env perl

use Test::More;

use Pipr::WS;

my %tests = (
    'http://foo.com/bar?a=1&b=2&a=3'  => 'f/d0/foo.com_bar0b1bd652ebbdf8159b280c804ac05ccc',
    'http://foo.com/bar?b=2&a=1&a=3'  => 'f/d0/foo.com_bar0b1bd652ebbdf8159b280c804ac05ccc',
    'https://foo.com/bar?b=2&a=1&a=3' => 'f/d0/foo.com_bar0b1bd652ebbdf8159b280c804ac05ccc',

    'http://foo.com/bar?b=2&a=1'     => '3/29/foo.com_bared04c91cf6f6ab5a01a31c0295c5da34',
    'http://foo.com/bar?a=1&b=2'     => '3/29/foo.com_bared04c91cf6f6ab5a01a31c0295c5da34',
);

while (my ($in, $exp) = each %tests) {
    is(Pipr::WS::_url2file($in), $exp, "$in => $exp");
}

done_testing;
