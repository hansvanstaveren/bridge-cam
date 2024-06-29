#!/usr/bin/env perl

use warnings;
use strict;

use Net::FTP;

my $HOST = "utopia.hacktic.nl";
my $PORT = 21;


print "about to ftp\n";

my $ftp = Net::FTP->new($HOST, Port => $PORT, Debug => 1, Passive => 1)
	or die "Cannot connect to $HOST: $@";
print "ftp succeeded: $ftp\n";
$ftp->login("anonymous", "sater\@xs4all.nl") or die "Cannot login ", $ftp->message;
print "lgin succeeded: \n";
foreach my $f ($ftp->ls()) { print "$f\n"; }
$ftp->quit;

