#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use Test::Mojo;

my $t = Test::Mojo->new('Pipr::WS');

$t->get_ok('/')->status_is(200, 'response status is 200 for /');

$t->get_ok('/lol')->status_is(404, 'response status is 200 for /');
$t->get_ok('/themes/pay/assets/core.css')->status_is(404, 'response status is 200 for /');

done_testing;
