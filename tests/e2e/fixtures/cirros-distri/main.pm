use Mojo::Base -strict;
use testapi;
use autotest;

if (get_var('SLEEPTEST')) {
    autotest::loadtest 'tests/sleep.pm';
} else {
    autotest::loadtest 'tests/boot.pm';
}

1;