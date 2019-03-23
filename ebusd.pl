#!/usr/bin/perl

$| = 1;

use strict;
use warnings;

use constant PORT      => "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A602DOJT-if00-port0";
use constant IP_SYM_IP => "172.18.0.2";

use Device::SerialPort;
use IO::Socket;
use IO::Select;

# system( "./resetusb /dev/bus/usb/001/005" );
# sleep( 10 );

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
$usb_dev->read_char_time( 0 );        # don't wait for each character
$usb_dev->read_const_time( 1000 );    # 1 second per unfulfilled "read" call
$usb_dev->write_settings;

my $chars        = 0;
my $buffer       = "";
my $expected_msg = "";
my $timeout      = 30;
my @data_to_send = ();

while ( $timeout > 0 ) {
    my ( $count, $saw ) = $usb_dev->read( 1 ) or die "usb dev read fail: $!\n";    # read only char by char

    while ( $select->can_read( 0.01 ) && $udp_server->recv( my $datagram, 1024 ) ) {

        # cleanup datagram
        $datagram =~ s/ //g;

        print "UDP got: $datagram\n";

        push( @data_to_send, $datagram );
    }

    if ( $count > 0 ) {
        $timeout = 30;
        $chars += $count;

        $saw = uc( unpack( "H*", $saw ) );

        #print "B: ".$saw,"\n";
        if ( $saw eq "AA" ) {

            # syn byte received send something from the queue
            if ( $buffer eq "" && defined( my $e = shift @data_to_send ) ) {
		$expected_msg = $e;
                $e = pack( "H*", $e );
                my $count_out = $usb_dev->write( $e ) or die "usb dev write fail: $!\n";
                warn "write failed\n" unless ( $count_out );
                warn "write incomplete\n" if ( $count_out != length( $e ) );
            }

            #use Data::Dumper;
            #print Dumper(\@msg);
	    # min length is 6 byte (hex * 2)
            if ( length( $buffer ) > 2*6 ) {
                print "OK: $buffer\n";
                udp_send( $buffer );
                $buffer = "";
            } elsif (length($buffer) > 0) {
		    print "skip inv.: $buffer\n";
		$buffer = "";
	    } 
        }
        else {
            # non syn byte add to buffer
            $buffer .= $saw;
	    if ($buffer eq $expected_msg) {
		    print "removing our own msg from buffer: $expected_msg\n";
		    $buffer = "";
		    $expected_msg = "";
	    }
        }
    }
    else {
        $timeout--;
    }
}

exit( 1 );

sub udp_send {
    $udp_client->send( @_ );
}
