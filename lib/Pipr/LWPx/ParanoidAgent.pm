package Pipr::LWPx::ParanoidAgent;

use strict;
use warnings;

use base 'LWPx::ParanoidAgent';

use Cache::LRU;

our $cache = Cache::LRU->new( size => 1000 );
our $cache_ttl = 3600;

our $etc_hosts_file = '/etc/hosts';
our $etc_hosts = {};
our $etc_hosts_ttl = 300;

sub _resolve {
    my ($self, $host, $request, $timeout, $depth) = @_;

    # Lookup in /etc/hosts first
    if (!$depth) {
        my $ip = $self->_parse_etc_hosts->{$host};
        return $ip if $ip;
    }

    my $cache_key = $host;

    if (my $value = $cache->get($cache_key)) {
        my ($res, $expires_at) = @$value;
        return @{ $res } if (time < $expires_at);
        $cache->remove($cache_key);
    }

    my @res = $self->SUPER::_resolve($host, $request, $timeout, $depth);

    $cache->set(
        $cache_key => [ [ @res ], time + $cache_ttl + 0.5 ],
    );

    return @res;
}

sub _parse_etc_hosts {
    my ($self, $hostsfile) = @_;

    return $etc_hosts->{hosts} if !$hostsfile &&  defined $etc_hosts->{last_cached_ts} && (time <= ($etc_hosts->{last_cached_ts} + $etc_hosts_ttl));

    $hostsfile ||= $etc_hosts_file;

    if (open my $fh, '<', $hostsfile) {
       $etc_hosts = {};
       while (<$fh>) {
           next if $_ =~ m{ \A \s* \# }gmx; # skip comments
           my ($ip, @hostnames) = split /\s+/, $_;
           next unless defined $ip && scalar @hostnames; # skip non-parseable lines or empty lines
           for my $hostname (@hostnames) {
               $etc_hosts->{hosts}->{$hostname} = $ip;
           }
       }
       $etc_hosts->{last_cached_ts} = time;
       close $fh;
    }
    return $etc_hosts->{hosts} || {};
}
