#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use Pipr::LWPx::ParanoidAgent;

my $ua = Pipr::LWPx::ParanoidAgent->new();

my @res1 = $ua->_resolve("www.google.com");
sleep 1;

my ($res_cached, $expires_at) = @{ $Pipr::LWPx::ParanoidAgent::cache->get("www.google.com") };
ok(($expires_at - time) < ( 3600 ), 'cache ttl is less than (3600): ' . ($expires_at - time));
ok(($expires_at - time) > ( 3598 ), 'cache ttl is greater than (3600 - 2): ' . ($expires_at - time));

my @res_after_cached = $ua->_resolve("www.google.com");

is_deeply(\@res1, $res_cached, 'Same result even if cached');
is_deeply(\@res1, \@res_after_cached, 'Same result after cached');

$Pipr::LWPx::ParanoidAgent::cache->clear();
$Pipr::LWPx::ParanoidAgent::cache_ttl = 1;
my @res2 = $ua->_resolve("www.google.com");
my ($res_cached2, $expires_at2) = @{ $Pipr::LWPx::ParanoidAgent::cache->get("www.google.com") };
sleep 1;
ok(($expires_at2 - time) < 1, 'cache ttl is less than 1:' . ($expires_at2 - time));

$Pipr::LWPx::ParanoidAgent::cache_ttl = 60;
sleep 1;
my @res3 = $ua->_resolve("www.google.com");
my ($res_cached3, $expires_at3) = @{ $Pipr::LWPx::ParanoidAgent::cache->get("www.google.com") };
ok(($expires_at3 - time) > 58, 'cache ttl is greater than 58:' .($expires_at3 - time));

$ua->_parse_etc_hosts('t/data/etc_hosts.txt');
is_deeply [$ua->_resolve("www.google.com")], ['127.0.0.1'], 'Reads correctly from hostsfile';
is_deeply [$ua->_resolve("fake_host")], ['127.0.0.2'], 'Reads correctly from hostsfile';

# MAke sure we don't crash with faulty hosts files
$ua->_parse_etc_hosts('/etc/passwd');
$ua->_parse_etc_hosts('t/data/non-existent-file');

done_testing;
