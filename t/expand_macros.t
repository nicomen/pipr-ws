use warnings;
use strict;

use Pipr::WS;
use Test::More;

my $tests = {
  'dev.pipr.example.com'  => 'dev',
  'dev-pipr.example.dev' => 'dev',
  'kua.pipr.example.com'  => 'kua',
  'kua-pipr.example.com'  => 'kua',
  'qa.pipr.example.com'   => 'kua',
  'qa-pipr.example.com'   => 'kua',
  'pipr-ws1.example.com'  => 'www',
  'kua.lol.no'              => 'www',
  'localhost'               => 'www',
};

while (my ($host, $subdomain) = each %{$tests}) {
    is(Pipr::WS::expand_macros('%ENV_SUBDOMAIN%', $host), $subdomain, "$host => $subdomain");
}

done_testing;
