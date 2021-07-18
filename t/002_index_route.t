#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use Test::Mojo;

my $t = Test::Mojo->new('Pipr::WS');

$t->get_ok('/')->status_is(200, 'response status is 200 for /');

done_testing;
