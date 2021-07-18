#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Image::Size;
use File::Temp qw/tempdir/;

my $t = Test::Mojo->new('Pipr::WS');

my $test_image_path = "public/images/test.png";

is_deeply(
  $t->get_ok("/test/dims/$test_image_path")->tx->res->json,
  { image => { width => 1280, height => 1024, type => 'png' } }, 
  'Check that dimensions are correct'
);

done_testing;
