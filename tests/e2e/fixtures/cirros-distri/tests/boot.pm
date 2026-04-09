use Mojo::Base 'basetest';
use testapi;

sub run {
    my ($self) = @_;

    # Wait for CirrOS to finish booting and show the login prompt.
    my $serial_output = wait_serial(qr/cirros login:/, timeout => 120);
    die 'Boot failed: login prompt not seen on serial console' unless $serial_output;

    # Capture the VNC screen for visual documentation
    save_screenshot;
}

1;