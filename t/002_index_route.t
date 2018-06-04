#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use Test::Mojo::Plack;

my $t = Test::Mojo::Plack->new('Pipr::WS');

$t->get_ok('/')->status_is(200, 'response status is 200 for /');

done_testing;
