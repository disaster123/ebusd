#!/usr/bin/perl

$| = 1;

use strict;
use warnings;

use constant PORT      => "/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A602DOJT-if00-port0";
use constant IP_SYM_IP => "172.18.0.2";

use Device::SerialPort;
use IO::Socket;
use IO::Select;

system( "./resetusb /dev/bus/usb/001/005" );
sleep( 10 );

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

my $chars   = 0;
my $buffer  = "";
my $timeout = 10;
while ( $timeout > 0 ) {
    my ( $count, $saw ) = $usb_dev->read( 10 ) or die "usb dev read fail: $!\n";    # will read _up to_ 10 chars

    while ( $select->can_read( 0.5 ) && $udp_server->recv( my $datagram, 1024 ) ) {

        # cleanup datagram
        $datagram =~ s/ //g;

        print "UDP got: $datagram\n";

        $datagram = pack( "H*", $datagram );
        my $count_out = $usb_dev->write( $datagram ) or die "usb dev write fail: $!\n";
        warn "write failed\n" unless ( $count_out );
        warn "write incomplete\n" if ( $count_out != length( $datagram ) );
    }

    if ( $count > 0 ) {
        $chars += $count;

        $buffer .= uc( unpack( "H*", $saw ) );

        #print "B: ".$buffer,"\n";
        if ( $buffer =~ /AA/ ) {
            my @msg = split( /AA/, $buffer );

            #use Data::Dumper;
            #print Dumper(\@msg);
            my $lok = 0;
            foreach my $i ( 0 .. $#msg ) {
                if (
                    length( $msg[$i] ) >= 17
                    && (   ( defined( $msg[ $i + 1 ] ) && $msg[ $i + 1 ] eq "" )
                        || ( $buffer =~ /^(AA)*$msg[$i]AA/ ) )
                  )
                {
                    print "OK: $msg[$i]\n";
                    udp_send( $msg[$i] );
                    $lok = $i + 1;
                }
            }
            $buffer = join( "AA", @msg[ $lok .. $#msg ] );

            # print "A: ".$buffer,"\n";
            $timeout = 10;
        }

        # Check here to see if what we want is in the $buffer
        # say "last" if we find it
    }
    else {
        $timeout--;
    }
}

exit( 1 );

sub udp_send {
    $udp_client->send( @_ );
}
