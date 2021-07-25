#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;
use Test::Mojo;
use Test::LongString;
use Data::Dumper;
use Image::Size;

use Path::Tiny qw/path/;

use_ok 'Pipr::WS';

my $t = Test::Mojo->new('Pipr::WS');

$t->app->config->{'allow_local_access'} = 1;

subtest 'test.png' => sub {
  my $test_image_path = "public/images/test.png";
  my $res = $t->get_ok("/test/p/$test_image_path")->status_is(200)->tx->res;
  is($res->headers->header('Content-Type'), 'image/x-png', 'Correct MIME-Type');
  my $proxied_file = $res->body;
  my $orig_file = path("share/$test_image_path")->slurp_raw;
  is_string($proxied_file, $orig_file, 'Files are identical');
};

subtest 'test.jpg' => sub {
  my $test_image_path = "public/images/test.jpg";
  my $res = $t->get_ok("/test/p/$test_image_path")->status_is(200)->tx->res;
  is($res->headers->header('Content-Type'), 'image/jpeg', 'Correct MIME-Type');
  my $proxied_file = $res->body;
  my $orig_file = path("share/$test_image_path")->slurp_raw;
  is_string($proxied_file, $orig_file, 'Files are identical');
};


done_testing;
