# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

# Summary: Inflate jobs/ID/details response via record_info loops
# Maintainer: openQAclient contributors

=head1 NAME

stress.pm - Generate a large jobs/ID/details API response

=head1 DESCRIPTION

Calls record_info() in a tight loop to produce many detail steps with
configurable-size text payloads.  The openQA API inlines each step's
text content into the jobs/ID/details JSON response, so the total
response size is approximately STRESS_STEPS * STRESS_TEXT_SIZE bytes.

This module does NOT interact with the SUT (no serial, no screen).
The qemu backend starts in the background but is unused.

=head1 SETTINGS

=over

=item B<STRESS_STEPS>

Number of record_info calls.

=item B<STRESS_TEXT_SIZE>

Bytes of text per step.

=back

=head1 EXAMPLE

With defaults: 800 steps * 50000 bytes = ~38 MB details response.

=cut

use Mojo::Base 'basetest';
use testapi;

sub run {
    my ($self) = @_;

    my $steps = get_required_var('STRESS_STEPS');
    my $size  = get_required_var('STRESS_TEXT_SIZE');
    my $blob  = 'A' x $size;

    for my $i (1 .. $steps) {
        record_info("step-$i", $blob);
    }
}

sub test_flags {
    return {fatal => 1};
}

1;
