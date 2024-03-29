use inc::Module::Install;

name 'Pipr-WS';
version '18.20190124-01';
# These override things fetched by 'all_from' below.
# They must come *before* the call to 'all_from'.
perl_version '5.010001';
license 'proprietary'; # the license type ('all_from' needs this)

configure_requires 'Module::Install' => 0;

# Perl modules needed for running the tests
test_requires 'Test::More';

# Perl modules needed at run-time
requires 'YAML::XS';
requires 'Crypt::SSLeay'; # SSL Support
requires 'Dancer' => 1.3202;
requires 'GD' => 0;
requires 'IO::Socket::SSL' => 0;
requires 'PerlIO::gzip';
requires 'JSON::Any' => 0;
requires 'List::Util' => 0;
requires 'Object::Signature' => 0;
requires 'POSIX' => 0;
requires 'File::Type' => 0;

requires 'Cache::LRU' => 0;
requires 'LWPx::ParanoidAgent' => 0;

requires 'LWP::UserAgent::Cached' => 0;
requires 'Path::Tiny';
requires 'Net::DNS' => 0.81;
requires 'Image::Size' => 0;
requires 'HTML::TreeBuilder' => 0;
requires 'File::Share' => 0;

requires 'Modern::Perl' => '1.20150127';
requires 'Template::Toolkit' => 0;
requires 'Mojolicious' => 0;
requires 'Mojolicious::Plugin::YamlConfig' => 0;
requires 'Mojolicious::Plugin::TtRenderer' => 0;
requires 'Mojolicious::Plugin::Systemd'    => 0;

test_requires 'Test::Mojo::Plack' => 0.13;
test_requires 'Test::Simple' => 0;
test_requires 'Test::LongString' => 0;

install_script glob('bin/*');

install_share 'share';

auto_install

tests_recursive;

WriteAll;

