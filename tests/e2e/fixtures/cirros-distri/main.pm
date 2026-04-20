use Mojo::Base -strict;
use testapi;
use autotest;

if (get_var('STRESSTEST')) {
    autotest::loadtest 'tests/stress.pm';
} elsif (get_var('SLEEPTEST')) {
    autotest::loadtest 'tests/sleep.pm';
} else {
    autotest::loadtest 'tests/boot.pm';
}

1;