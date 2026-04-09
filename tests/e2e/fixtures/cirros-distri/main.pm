use Mojo::Base -strict;
use testapi;
use autotest;

autotest::loadtest 'tests/boot.pm';

1;