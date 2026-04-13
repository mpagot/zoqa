use Mojo::Base 'basetest';
use testapi;

sub run {
    my ($self) = @_;

    # Sleep in small increments so os-autoinst can process cancellation
    # signals between iterations. Total: up to 300 seconds.
    for (1 .. 300) {
        sleep 1;
    }
}

1;