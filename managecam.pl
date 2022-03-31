#!/usr/bin/perl

#
# Software for Bridge_CARE camera setup and backup
#
# Author: Hans van Staveren <sater@xs4all.nl>
#

use strict;
use warnings;

use XML::Simple;
use Data::Dumper;
use LWP::Simple;
use List::Util qw(shuffle);

my $coldconf;
#
# user/password stuff
#
my $resetpw;
my $ourpw = "wbf123";

my $ftpuser = "ftpuser";
my $ftppass = "ftp123";
my $default_basedir = "/usbdisk/wtc2021";
#
# Network stuff
#
my $dhcpcamip="";
my $cambase = 0;	# Number to add to camera to get 4th octet IP address
my $cammin = 1;
my $cammax = 150;

my $camnet = "172.16.12.";
my $camnetmask = "255.255.255.0";
my $gateway = "254";		# 254 and not 1, to be able to use camera #1

my $ip_gateway = $camnet . $gateway;

my $hours_after_gmt = 1;
my $hours_dst = 1;

my $camport = 88;

my $wifinet = "bridge-care";
my $wifipw = "brc-0000";

#
# Recording times
#

my $lowhalf = 20;	# 10h00
my $highhalf = 40;	# 20h00

my $quietflag = "-nv";

sub prompt {
    my ($pr) = @_;

    print ("$pr: ");
    my $ans = <>;
    chomp $ans;
    # print "Prompt $pr returning $ans\n";
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
    my $prefix = "http://$camip:$camport/cgi-bin/CGIProxy.fcgi?";
    my $auth = "usr=admin&pwd=$pw";

    my $curlcmd = "curl -s --connect-timeout 5 '$prefix$auth&$str'";
    # print "curlcmd = $curlcmd\n";
    my $res = `$curlcmd`;
    # print "res = $res\n";
    if ($res !~ /</) {
	return 0;
    }
    my $parsed = XMLin($res);

    my $result = $parsed->{result};
    if ($result != 0) {
	print "Error $result\n";
    } else {
	    # print Dumper($parsed), "\n";
    }
    return $result == 0;
}

sub sendcmd {
    my ($cam, $cmd, $argptr) = @_;
    my %args = %$argptr;

    # print Dumper(\%args), "\n";
    my $argstr = "";
    foreach my $key (keys%args) {
	$argstr .= "$key=$args{$key}&";
    }
    $argstr .= "cmd=$cmd";
    # print "args = $argstr\n";
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
    $args{gate} = $ip_gateway;
    $args{dns1} = $ip_gateway;
    $args{dns2} = $ip_gateway;
    return sendcmd($cam, "setIpInfo", \%args);
}

sub devname {
    my ($cam) = @_;

    return "BRC-$cam";
}

sub set_devname {
    my ($cam) = @_;
    my %args;

    $args{devName} = devname($cam);
    return sendcmd($cam, "setDevName", \%args);
}

sub set_system_time {
    my ($cam) = @_;
    my %args;

    $args{timeSource} = 0;
    $args{ntpServer} = $ip_gateway;
    $args{dateFormat} = 0;
    $args{timeFormat} = 1;
    $args{timeZone} = -3600*$hours_after_gmt;
    $args{isDst} = $hours_dst;
    return sendcmd($cam, "setSystemTime", \%args);
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

sub set_infrared_manual {
    my ($cam) = @_;
    my %args;

    $args{mode} = 1;
    return sendcmd($cam, "setInfraLedConfig", \%args);
}

sub set_infrared_off {
    my ($cam) = @_;
    my %args;

    return sendcmd($cam, "closeInfraLed", \%args);
}

sub set_schedule_record {
    my ($cam, $onoff, $wraparound, $audio) = @_;
    my %args;

    $args{isEnable} = $onoff;
    $args{spaceFullMode} = $wraparound ? 0 : 1;
    $args{isEnableAudio} = $audio;
    my $sum = 0;
    foreach my $i ($lowhalf..$highhalf-1) {
	$sum += 2**$i;
    }
    # All days of the week
    $args{schedule0} = $sum;
    $args{schedule1} = $sum;
    $args{schedule2} = $sum;
    $args{schedule3} = $sum;
    $args{schedule4} = $sum;
    $args{schedule5} = $sum;
    $args{schedule6} = $sum;
    return sendcmd($cam, "setScheduleRecordConfig", \%args);
}

sub set_ftp_account {
    my ($cam, $userid, $pass, $privilege) = @_;
    my %args;

    $args{usrName} = $userid;
    $args{usrPwd} = $pass;
    $args{privilege} = $privilege;
    return sendcmd($cam, "addAccount", \%args);
}

sub start_ftp {
    my ($cam) = @_;
    my %args;

    return sendcmd($cam, "startFtpServer", \%args);
}

sub copy_files {
    my ($cam, $basedir) = @_;

    my $name = devname($cam);
    my $dirname = "$basedir$name";
    my $camip = $camnet . ($cam+$cambase);
    my $pw = $ourpw;
    unless (-d $dirname) { print "Creating directory $dirname\n"; mkdir $dirname }
    chdir $dirname;
    system("(date;echo starting copy)>>Copytimes");
    print "wget $quietflag -a Logfile -A schedule\\*.avi --mirror -nH -r 'ftp://$ftpuser:$ftppass\@$camip:50021/'\n";
    system("wget $quietflag -a Logfile -A schedule\\*.avi --mirror -nH -r 'ftp://$ftpuser:$ftppass\@$camip:50021/'");
    system("(date;echo ending copy)>>Copytimes");
}

sub copy_files_allcam {
    my ($simul, $basedir, @camnumbers) = @_;
    my $cam;
    my @camtocopy;
    my @camdown;
    my $children = 0;

    print "Backup cameras @camnumbers in directory $basedir\n";
    for $cam (@camnumbers) {
	if (start_ftp($cam, $basedir)) {
	    # Camera is on, ftp started
	    push @camtocopy, $cam;
	} else {
	    # Camera seems off
	    push @camdown, $cam;
	}
    }
    print "Cameras down: @camdown\n";

    # @camtocopy = shuffle(@camtocopy);
    print "Will copy cameras in order: @camtocopy\n";

    while ($cam = shift @camtocopy) {
	if ($children == $simul) {
	    # Enough running in background
	    # Wait for one to finish
	    print "Wanting to copy $cam, but must wait\n";
	    my $pid = wait();
	    die "Wait failed" if ($pid < 0);
	    $children--;
	}
	my $pid = fork();
	die "Fork failed" unless(defined($pid));
	if ($pid != 0) {
	    # Parent
	    $children++;
	    print "Started copy of camera $cam, now $children children\n";
	} else {
	    # Child
	    copy_files($cam, $basedir);
	    exit(0);
	}
    }

    #
    # Wait for rest of children
    #
    do {
	print "Waiting for $children children\n";
	# Nothing
    } while (wait() > 0);
}

sub splitgrp {
    my @flds = @_;

    my $result = "";
    for (@flds) {
	# print "next field $_\n";
	if (/^([0-9]+)-([0-9]+)$/) {
	    # print "range $1 to $2\n";
	    for ($1..$2) {
		$result = $result . " $_";
	    }
	} else {
	    # print "single number $_\n";
	    $result = $result . " $_";
	}
	# print "Result now: $result\n";
    }
    return $result;
}

while(1) {
    my $command = prompt("Init or Backup or Groupbackup");
    if ($command =~ /^[Ii].*/) {
	# Init
	my $cam = prompt("Camera number");
	if ($cam < $cammin || $cam > $cammax) {
	    print "Should be between $cammin and $cammax inclusive\n";
	    next;
	}
	$dhcpcamip = prompt("Current IP address if different");
	$coldconf = $dhcpcamip ne "";
	if ($coldconf) {
	    if ($dhcpcamip =~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
		print "Complete IP address $dhcpcamip\n";
	    } elsif ($dhcpcamip =~ /^[0-9]+$/) {
		$dhcpcamip = "$camnet$dhcpcamip";
		print "Completed IP address $dhcpcamip\n";
	    } else {
		print "Wrong IP address $dhcpcamip\n";
		next;
	    }

	    $resetpw = "";
	    change_passwd($cam, $resetpw, $ourpw);
	}
	$resetpw = $ourpw;

	set_devname($cam);
	set_system_time($cam);
	set_wifi($cam);

	set_motion_detect($cam, 0);
	set_alarm_record($cam, 0);
	set_schedule_record($cam, 1, 1, 1);
	set_infrared_manual($cam);
	set_infrared_off($cam);

	set_ftp_account($cam, $ftpuser, $ftppass, 2);

	if ($coldconf) {
	    # And finally (reboot will occur)
	    set_ip($cam);
	}

	$dhcpcamip = "";
    } elsif ($command =~ /^[Bb].*/) {
	# Backup
	my $range=prompt("low-high cam numbers");
	$range =~ /^([0-9]*)(-([0-9]*))?$/;
	my $low = $1;
	my $high = defined($3) ? $3 : $1;
	my $simul = prompt("Simultaneous copies?");
	my $basedir = prompt("Directory for storage [$default_basedir]");
	if ($basedir eq "") {
	    $basedir = $default_basedir;
	}
	$basedir .= "/";
	copy_files_allcam($simul, $basedir, $low..$high);
    } elsif ($command =~ /^[Gg].*/) {
	# Group backup
	my $children=0;
	my $basedir = prompt("Directory for storage [$default_basedir]");
	if ($basedir eq "") {
	    $basedir = $default_basedir;
	}
	$basedir .= "/";

	open (GROUP, '<', "groupinfo") || die "Group info missing";
	while (<GROUP>) {
	    chomp;
	    my @flds = split;
	    my $simul = shift @flds;
	    print "Simul $simul, rest @flds\n";
	    my $grprest = splitgrp(@flds);
	    print "Backup $grprest\n";

	    my $pid = fork();
	    if ($pid == 0) {
		print "Backup in child $grprest\n";
		my @camnumbers = split(" ", $grprest);
		print "As array: @camnumbers\n";
		copy_files_allcam($simul, $basedir, @camnumbers);
		exit();
	    } else {
		$children++;
	    }
	}
	close GROUP;
	for (1..$children) {
	    my $pid = wait();
	}
    } else {
	print "Goodbye!\n";
	last;
    }
}
