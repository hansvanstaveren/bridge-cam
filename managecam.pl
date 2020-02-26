#!/usr/bin/perl

use strict;
use warnings;

use XML::Simple;
use Data::Dumper;
use LWP::Simple;

#
# user/password stuff
#
my $resetpw;
my $ourpw = "wbf123";
#
# Network stuff
#
my $dhcpcamip="";
my $cambase = 0;	# Number to add to camera to get 4th octet IP address
my $camnet = "172.16.12.";
my $camnetmask = "255.255.255.0";
my $gateway = "254";

my $camport = 88;

my $wifinet = "bridge-cam";
my $wifipw = "bridge-cam";

my $maxcam = 5;

my $maxchildren = 10;
my $quietflag = "";

sub prompt {
    my ($pr) = @_;

    print ("$pr: ");
    my $ans = <>;
    chomp $ans;
    print "Prompt $pr returning $ans\n";
    return $ans;
}

sub curl {
    my ($cam, $str) = @_;
    my $camip;
    my $pw;

    if ($dhcpcamip ne "") {
	$camip = $dhcpcamip;
	$pw = $resetpw;
    } else {
	$camip = $camnet . ($cam+$cambase);
	$pw = $ourpw;
    }
    my $pref = "http://$camip:$camport/cgi-bin/CGIProxy.fcgi?";
    my $auth = "usr=admin&pwd=$pw";

    my $curlcmd = "curl -s --connect-timeout 5 '$pref$auth&$str'";
    print "curlcmd = $curlcmd\n";
    my $res = `$curlcmd`;
    print "res = $res\n";
    if ($res !~ /</) {
	return 0;
    }
    my $parsed = XMLin($res);

    my $result = $parsed->{result};
    if ($result != 0) {
	print "Error $result\n";
    } else {
	print Dumper($parsed), "\n";
    }
    return $result == 0;
}

sub sendcmd {
    my ($cam, $cmd, $argptr) = @_;
    my %args = %$argptr;

    print Dumper(\%args), "\n";
    my $argstr = "";
    foreach my $key (keys%args) {
	$argstr .= "$key=$args{$key}&";
    }
    $argstr .= "cmd=$cmd";
    print "args = $argstr\n";
    return curl($cam, $argstr);
}

sub change_passwd {
    my ($cam, $oldpw, $newpw) = @_;
    my %args;

    $args{usrName} = "admin";
    $args{oldPwd} = $oldpw;
    $args{newPwd} = $newpw;
    return sendcmd($cam, "changePassword", \%args);
}

sub set_ip {
    my ($cam) = @_;
    my %args;

    $args{DHCP} = 0;
    $args{ip} = $camnet . ( $cam+$cambase );
    $args{mask} = $camnetmask;
    $args{gate} = $camnet . $gateway;
    $args{dns1} = $camnet . $gateway;
    $args{dns2} = $camnet . $gateway;
    return sendcmd($cam, "setIpInfo", \%args);
}

sub set_devname {
    my ($cam) = @_;
    my %args;

    $args{devName} = "bridge_cam_$cam";
    return sendcmd($cam, "setDevName", \%args);
}

sub set_wifi {
    my ($cam) = @_;
    my %args;

    $args{isEnable} = 1;
    $args{isUseWifi} = 1;
    $args{ssid} = $wifinet;
    $args{netType} = 0;
    $args{encryptType} = 3;
    $args{keyFormat} = 0;
    $args{psk} = $wifipw;
    $args{authMode} = 2;
    return sendcmd($cam, "setWifiSetting", \%args);
}

sub set_motion_detect {
    my ($cam, $onoff) = @_;
    my %args;

    $args{isEnable} = $onoff;
    return sendcmd($cam, "setMotionDetectConfig", \%args);
}

sub set_alarm_record {
    my ($cam, $onoff) = @_;
    my %args;

    $args{isEnablePreRecord} = $onoff;
    return sendcmd($cam, "setAlarmRecordConfig", \%args);
}

sub set_schedule_record {
    my ($cam, $onoff, $wraparound, $audio) = @_;
    my %args;
    my $lowhalf = 20;	# 10AM
    my $highhalf = 38;	# 7PM

    $args{isEnable} = $onoff;
    $args{spaceFullMode} = $wraparound ? 0 : 1;
    $args{isEnableAudio} = $audio;
    my $sum = 0;
    foreach my $i ($lowhalf..$highhalf-1) {
	$sum += 2**$i;
    }
    $args{schedule0} = $sum;
    $args{schedule1} = $sum;
    $args{schedule2} = $sum;
    $args{schedule3} = $sum;
    $args{schedule4} = $sum;
    $args{schedule5} = $sum;
    $args{schedule6} = $sum;
    return sendcmd($cam, "setScheduleRecordConfig", \%args);
}

sub start_ftp {
    my ($cam) = @_;
    my %args;

    return sendcmd($cam, "startFtpServer", \%args);
}

sub copy_files {
    my ($cam) = @_;

    my $camip = $camnet . ($cam+$cambase);
    my $pw = $ourpw;
    system("wget $quietflag --mirror -nH -r 'ftp://admin:$pw\@$camip:50021/'");
}

sub copy_files_allcam {
    my ($low, $high) = @_;
    my $cam;
    my @camtocopy;
    my $children = 0;

    for $cam ($low..$high) {
	if (start_ftp($cam)) {
	    # Camera is on, ftp started
	    push @camtocopy, $cam;
	}
    }
    while ($cam = shift @camtocopy) {
	if ($children == $maxchildren) {
	    # Enough running in background
	    # Wait for one to finish
	    my $pid = wait();
	    die "Wait failed" if ($pid < 0);
	    $children--;
	}
	my $pid = fork();
	die "Fork failed" unless(defined($pid));
	if ($pid != 0) {
	    # Parent
	    $children++;
	} else {
	    # Child
	    copy_files($cam);
	    exit(0);
	}
    }

    #
    # Wait for rest of children
    #
    do {
	# Nothing
    } while (wait() > 0);
}

do {
    my $command = prompt("Init or Backup");
    if ($command =~ /^[Ii].*/) {
	# Init
	my $cam = prompt("Camera number");
	$dhcpcamip = prompt("Current IP address");
	$resetpw = "";
	# $resetpw = $ourpw;
	change_passwd($cam, $resetpw, $ourpw);
	$resetpw = $ourpw;

	set_devname($cam);
	set_wifi($cam);

	set_motion_detect($cam, 0);
	set_alarm_record($cam, 0);
	set_schedule_record($cam, 1, 1, 1);

	# And finally (reboot will occur)
	set_ip($cam);

	$dhcpcamip = "";
    } elsif ($command =~ /^[Bb].*/) {
	# Backup
	my $range=prompt("low-high cam numbers");
	$range =~ /^([0-9]*)-([0-9]*)$/;
	copy_files_allcam($1, $2);
    } else {
	die "command";
    }
} while (1);
