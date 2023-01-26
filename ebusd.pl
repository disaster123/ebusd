#!/usr/bin/perl

$| = 1;

use strict;
use warnings;

use constant PORT      => "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A602DOJT-if00-port0";
use constant IP_SYM_IP => "172.18.0.2";

use Device::SerialPort;
use IO::Socket;
use IO::Select;

my $usb_dev = Device::SerialPort->new( PORT ) or die "Can't open device: $!\n";
my $udp_client = IO::Socket::INET->new( Proto => "udp", PeerHost => IP_SYM_IP, PeerPort => 8814 )
  or die "Can't create udp client: $@\n";
my $udp_server = IO::Socket::INET->new( LocalPort => 8812, Proto => "udp" ) or die "Can't create UDP server: $@";
my $select = IO::Select->new();
$select->add( $udp_server );

$usb_dev->baudrate( 2400 );
$usb_dev->parity( "none" );
$usb_dev->databits( 8 );
$usb_dev->stopbits( 1 );
$usb_dev->error_msg( 1 );    # prints hardware messages like "Framing Error"
$usb_dev->user_msg( 1 );     # prints function messages like "Waiting for CTS"
$usb_dev->handshake( "none" );
$usb_dev->buffers( 4096, 4096 );
$usb_dev->read_char_time( 5 );
$usb_dev->read_const_time( 100 );
$usb_dev->write_settings;

my $chars             = 0;
my $buffer            = "";
my $timeout           = 30;
my @data_to_send      = ();
my $zero_detect       = 0;
my $wait_for_next_syn = 0;
while ( $timeout > 0 ) {
    my ( $count, $saw ) = $usb_dev->read( 1 ) or die "usb dev read fail: $!\n";    # read only char by char

    if ( $count > 0 ) {
        $timeout = 30;
        $chars += $count;

        $saw = uc( unpack( "H*", $saw ) );

        if ( $zero_detect ) {
            $zero_detect = 0;
            next if $saw eq "00";
        }

        if ( $wait_for_next_syn ) {
            if ( $saw eq "AA" ) {
                $wait_for_next_syn = 0;
            }
            else {
                next;
            }
        }

        #print "B: ".$saw,"\n";
        if ( $saw eq "AA" ) {

            # min length is 6 byte (hex * 2)
            if ( length( $buffer ) >= 2 * 6 ) {
		    # print "OK: $buffer\n";
                udp_send( $buffer );
                $buffer = "";
            }
            elsif ( length( $buffer ) > 0 ) {
		    # print "skip inv.: $buffer $saw\n";
                $buffer = "";
            }

            my ( $BlockingFlags, $InBytes, $OutBytes, $ErrorFlags ) = $usb_dev->status;

            # print "-$InBytes $OutBytes-\n";

            # syn byte received send something from the queue
            # if ( $buffer eq "" && defined( my $e = shift @data_to_send ) ) {
            if ( $InBytes == 0 && defined( my $e = shift @data_to_send ) ) {
                my $abort       = 0;
                my $e_bin       = pack( "H*", $e );
                my @msg_to_send = split( //, $e_bin );
                my $byte_count  = 0;
                foreach my $byte ( @msg_to_send ) {
                    $byte_count++;
                    my $count_out = $usb_dev->write( $byte ) or die "usb dev write fail: $!\n";
                    my ( $count, $saw ) = $usb_dev->read( 1 );

                    # print unpack("H*",$byte)." ".unpack("H*", $saw)."\n";
                    if ( $saw ne $byte ) {
                        $saw = uc( unpack( "H*", $saw ) );

                        # if error occoured on first byte and it's not another SYN add it to the buffer
                        if ( $byte_count == 1 && $saw ne "AA" ) {
                            $buffer = uc( unpack( "H*", $saw ) );
                        }

                        # requeue
                        @data_to_send      = ( $e, @data_to_send );
                        $abort             = 1;
                        $wait_for_next_syn = 1;
                        last;
                    }
                }
                if ( !$abort ) {
			# print "msg send ok: $e Queue:" . scalar( @data_to_send ) . "\n";
                    $zero_detect = 1;

                    # our own msg was sent - so add to buffer
                    $buffer = $e;
                }
            }

        }
        else {
            # non syn byte add to buffer
            $buffer .= $saw;
        }
    }
    else {
        $timeout--;
    }

    while ( $select->can_read( 0.01 ) && $udp_server->recv( my $datagram, 1024 ) ) {

        # cleanup datagram
        $datagram =~ s/ //g;

	# print "UDP got: $datagram\n";

        push( @data_to_send, $datagram ) if !grep { $_ eq $datagram } @data_to_send;
    }

}

exit( 1 );

sub udp_send {
    $udp_client->send( @_ );
}
