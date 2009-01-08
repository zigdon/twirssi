use strict;
use Irssi;
use Irssi::Irc;
use HTTP::Date;
use HTML::Entities;
use File::Temp;
use LWP::Simple;
use Data::Dumper;
$Data::Dumper::Indent = 1;

BEGIN {
    $ENV{JSON_ANY_ORDER} = "JSON Syck DWIW";
    require JSON::Any;
    import JSON::Any;
    require Net::Twitter;
    import Net::Twitter;
}

use vars qw($VERSION %IRSSI);

$VERSION = "1.7.2";
my ($REV) = '$Rev: 351 $' =~ /(\d+)/;
%IRSSI = (
    authors     => 'Dan Boger',
    contact     => 'zigdon@gmail.com',
    name        => 'twirssi',
    description => 'Send twitter updates using /tweet.  '
      . 'Can optionally set your bitlbee /away message to same',
    license => 'GNU GPL v2',
    url     => 'http://tinyurl.com/twirssi',
    changed => '$Date: 2009-01-06 19:33:41 -0800 (Tue, 06 Jan 2009) $',
);

my $window;
my $twit;
my %twits;
my $user;
my $poll;
my %nicks;
my %friends;
my $last_poll = time - 300;
my %tweet_cache;
my %id_map;

sub cmd_direct {
    my ( $data, $server, $win ) = @_;

    unless ($twit) {
        &notice("Not logged in!  Use /twitter_login username pass!");
        return;
    }

    my ( $target, $text ) = split ' ', $data, 2;
    unless ( $target and $text ) {
        &notice("Usage: /dm <nick> <message>");
        return;
    }

    &cmd_direct_as( "$user $data", $server, $win );
}

sub cmd_direct_as {
    my ( $data, $server, $win ) = @_;

    unless ($twit) {
        &notice("Not logged in!  Use /twitter_login username pass!");
        return;
    }

    my ( $username, $target, $text ) = split ' ', $data, 3;
    unless ( $username and $target and $text ) {
        &notice("Usage: /dm_as <username> <nick> <message>");
        return;
    }

    unless ( exists $twits{$username} ) {
        &notice("Unknown username $username");
        return;
    }

    eval {
        unless ( $twits{$username}
            ->new_direct_message( { user => $target, text => $text } ) )
        {
            &notice("DM to $target failed");
            return;
        }
    };

    if ($@) {
        &notice("DM caused an error.  Aborted");
        return;
    }

    &notice("DM sent to $target");
    $nicks{$target} = time;
}

sub cmd_tweet {
    my ( $data, $server, $win ) = @_;

    unless ($twit) {
        &notice("Not logged in!  Use /twitter_login username pass!");
        return;
    }

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice("Usage: /tweet <update>");
        return;
    }

    &cmd_tweet_as( "$user $data", $server, $win );
}

sub cmd_tweet_as {
    my ( $data, $server, $win ) = @_;

    unless ($twit) {
        &notice("Not logged in!  Use /twitter_login username pass!");
        return;
    }

    $data =~ s/^\s+|\s+$//;
    my ( $username, $data ) = split ' ', $data, 2;

    unless ( $username and $data ) {
        &notice("Usage: /tweet_as <username> <update>");
        return;
    }

    unless ( exists $twits{$username} ) {
        &notice("Unknown username $username");
        return;
    }

    if ( Irssi::settings_get_str("short_url_provider") ) {
        foreach my $url ( $data =~ /(https?:\/\/\S+[\w\/])/g ) {
            eval {
                my $short = makeashorterlink($url);
                $data =~ s/\Q$url/$short/g;
            };
        }
    }

    if ( length $data > 140 ) {
        &notice(
            "Tweet too long (" . length($data) . " characters) - aborted" );
        return;
    }

    eval {
        unless ( $twits{$username}->update($data) )
        {
            &notice("Update failed");
            return;
        }
    };

    if ($@) {
        &notice("Update caused an error.  Aborted.");
        return;
    }

    foreach ( $data =~ /@([-\w]+)/ ) {
        $nicks{$1} = time;
    }

    my $away = 0;
    if (    Irssi::settings_get_bool("tweet_to_away")
        and $data !~ /\@\w/
        and $data !~ /^[dD] / )
    {
        my $server =
          Irssi::server_find_tag( Irssi::settings_get_str("bitlbee_server") );
        if ($server) {
            $server->send_raw("away :$data");
            $away = 1;
        } else {
            &notice( "Can't find bitlbee server.",
                "Update bitlbee_server or disable tweet_to_away" );
        }
    }

    &notice( "Update sent" . ( $away ? " (and away msg set)" : "" ) );
}

sub cmd_reply {
    my ( $data, $server, $win ) = @_;

    unless ($twit) {
        &notice("Not logged in!  Use /twitter_login username pass!");
        return;
    }

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice("Usage: /reply <nick[:num]> <update>");
        return;
    }

    $data =~ s/^\s+|\s+$//;
    my ( $id, $data ) = split ' ', $data, 2;
    unless ( $id and $data ) {
        &notice("Usage: /reply_as <nick[:num]> <update>");
        return;
    }

    &cmd_reply_as( "$user $id $data", $server, $win );
}

sub cmd_reply_as {
    my ( $data, $server, $win ) = @_;

    unless ( Irssi::settings_get_bool("twirssi_track_replies") ) {
        &notice("twirssi_track_replies is required in order to reply to "
              . "specific tweets.  Either enable it, or just use /tweet "
              . "\@username <text>." );
        return;
    }

    unless ($twit) {
        &notice("Not logged in!  Use /twitter_login username pass!");
        return;
    }

    $data =~ s/^\s+|\s+$//;
    my ( $username, $id, $data ) = split ' ', $data, 3;

    unless ( $username and $data ) {
        &notice("Usage: /reply_as <username> <nick[:num]> <update>");
        return;
    }

    unless ( exists $twits{$username} ) {
        &notice("Unknown username $username");
        return;
    }

    my $nick;
    $id =~ s/[^\w\d\-:]+//g;
    ( $nick, $id ) = split /:/, $id;
    unless ( exists $id_map{ lc $nick } ) {
        &notice("Can't find a tweet from $nick to reply to!");
        return;
    }

    $id = $id_map{__indexes}{$nick} unless $id;
    unless ( $id_map{ lc $nick }[$id] ) {
        &notice("Can't find a tweet numbered $id from $nick to reply to!");
        return;
    }

    # remove any @nick at the beginning of the reply, as we'll add it anyway
    $data =~ s/^\s*\@?$nick\s*//;
    $data = "\@$nick " . $data;

    if ( Irssi::settings_get_str("short_url_provider") ) {
        foreach my $url ( $data =~ /(https?:\/\/\S+[\w\/])/g ) {
            eval {
                my $short = makeashorterlink($url);
                $data =~ s/\Q$url/$short/g;
            };
        }
    }

    if ( length $data > 140 ) {
        &notice(
            "Tweet too long (" . length($data) . " characters) - aborted" );
        return;
    }

    eval {
        unless (
            $twits{$username}->update(
                {
                    status                => $data,
                    in_reply_to_status_id => $id_map{ lc $nick }[$id]
                }
            )
          )
        {
            &notice("Update failed");
            return;
        }
    };

    if ($@) {
        &notice("Update caused an error.  Aborted");
        return;
    }

    foreach ( $data =~ /@([-\w]+)/ ) {
        $nicks{$1} = time;
    }

    my $away = 0;
    if (    Irssi::settings_get_bool("tweet_to_away")
        and $data !~ /\@\w/
        and $data !~ /^[dD] / )
    {
        my $server =
          Irssi::server_find_tag( Irssi::settings_get_str("bitlbee_server") );
        if ($server) {
            $server->send_raw("away :$data");
            $away = 1;
        } else {
            &notice( "Can't find bitlbee server.",
                "Update bitlbee_server or disalbe tweet_to_away" );
        }
    }

    &notice( "Update sent" . ( $away ? " (and away msg set)" : "" ) );
}

sub gen_cmd {
    my ( $usage_str, $api_name, $post_ref ) = @_;

    return sub {
        my ( $data, $server, $win ) = @_;

        unless ($twit) {
            &notice("Not logged in!  Use /twitter_login username pass!");
            return;
        }

        $data =~ s/^\s+|\s+$//;
        unless ($data) {
            &notice("Usage: $usage_str");
            return;
        }

        eval {
            unless ( $twit->$api_name($data) )
            {
                &notice("$api_name failed");
                return;
            }
        };

        if ($@) {
            &notice("$api_name caused an error.  Aborted.");
            return;
        }

        &$post_ref($data) if $post_ref;
      }
}

sub cmd_switch {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    if ( exists $twits{$data} ) {
        &notice("Switching to $data");
        $twit = $twits{$data};
        $user = $data;
    } else {
        &notice("Unknown user $data");
    }
}

sub cmd_logout {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    if ( $data and exists $twits{$data} ) {
        &notice("Logging out $data...");
        $twits{$data}->end_session();
        delete $twits{$data};
    } elsif ($data) {
        &notice("Unknown username '$data'");
    } else {
        &notice("Logging out $user...");
        $twit->end_session();
        undef $twit;
        delete $twits{$user};
        if ( keys %twits ) {
            &cmd_switch( ( keys %twits )[0], $server, $win );
        } else {
            Irssi::timeout_remove($poll) if $poll;
            undef $poll;
        }
    }
}

sub cmd_login {
    my ( $data, $server, $win ) = @_;
    my $pass;
    if ($data) {
        ( $user, $pass ) = split ' ', $data, 2;
    } elsif ( my $autouser = Irssi::settings_get_str("twitter_usernames")
        and my $autopass = Irssi::settings_get_str("twitter_passwords") )
    {
        my @user = split /\s*,\s*/, $autouser;
        my @pass = split /\s*,\s*/, $autopass;
        if ( @user != @pass ) {
            &notice("Number of usernames doesn't match "
                  . "the number of passwords - auto-login failed" );
        } else {
            my ( $u, $p );
            while ( @user and @pass ) {
                $u = shift @user;
                $p = shift @pass;
                &cmd_login("$u $p");
            }
            return;
        }
    } else {
        &notice("/twitter_login requires either a username and password "
              . "or twitter_usernames and twitter_passwords to be set." );
        return;
    }

    %friends = %nicks = ();

    $twit = Net::Twitter->new(
        username => $user,
        password => $pass,
        source   => "twirssi"
    );

    unless ( $twit->verify_credentials() ) {
        &notice("Login as $user failed");
        $twit = undef;
        if ( keys %twits ) {
            &cmd_switch( ( keys %twits )[0], $server, $win );
        }
        return;
    }

    if ($twit) {
        my $rate_limit = $twit->rate_limit_status();
        if ( $rate_limit and $rate_limit->{remaining_hits} < 1 ) {
            &notice("Rate limit exceeded, try again later");
            $twit = undef;
            return;
        }

        $twits{$user} = $twit;
        Irssi::timeout_remove($poll) if $poll;
        $poll = Irssi::timeout_add( 300 * 1000, \&get_updates, "" );
        &notice("Logged in as $user, loading friends list...");
        &load_friends();
        &notice( "loaded friends: ", scalar keys %friends );
        if ( Irssi::settings_get_bool("twirssi_first_run") ) {
            Irssi::settings_set_bool( "twirssi_first_run", 0 );
            unless ( exists $friends{twirssi} ) {
                &notice("Welcome to twirssi!"
                      . "  Perhaps you should add \@twirssi to your friends list,"
                      . " so you can be notified when a new version is release?"
                      . "  Just type /twitter_friend twirssi." );
            }
        }
        %nicks = %friends;
        $nicks{$user} = 0;
        &get_updates;
    } else {
        &notice("Login failed");
    }
}

sub cmd_upgrade {
    my ( $data, $server, $win ) = @_;

    my $loc = Irssi::settings_get_str("twirssi_location");
    unless ( -w $loc ) {
        &notice(
"$loc isn't writable, can't upgrade.  Perhaps you need to /set twirssi_location?"
        );
        return;
    }

    if ( not -x "/usr/bin/md5sum" and not $data ) {
        &notice(
"/usr/bin/md5sum can't be found - try '/twirssi_upgrade nomd5' to skip MD5 verification"
        );
        return;
    }

    my $md5;
    unless ($data) {
        eval { use Digest::MD5; };

        if ($@) {
            &notice(
"Failed to load Digest::MD5.  Try '/twirssi_upgrade nomd5' to skip MD5 verification"
            );
            return;
        }

        $md5 = get("http://twirssi.com/md5sum");
        chomp $md5;
        $md5 =~ s/ .*//;
        unless ($md5) {
            &notice("Failed to download md5sum from peeron!  Aborting.");
            return;
        }

        unless ( open( CUR, $loc ) ) {
            &notice(
"Failed to read $loc.  Check that /set twirssi_location is set to the correct location."
            );
            return;
        }

        my $cur_md5 = Digest::MD5::md5_hex(<CUR>);
        close CUR;

        if ( $cur_md5 eq $md5 ) {
            &notice("Current twirssi seems to be up to date.");
            return;
        }
    }

    my $URL = "http://twirssi.com/twirssi.pl";
    &notice("Downloading twirssi from $URL");
    LWP::Simple::getstore( $URL, "$loc.upgrade" );

    unless ($data) {
        unless ( open( NEW, "$loc.upgrade" ) ) {
            &notice(
"Failed to read $loc.upgrade.  Check that /set twirssi_location is set to the correct location."
            );
            return;
        }

        my $new_md5 = Digest::MD5::md5_hex(<NEW>);
        close NEW;

        if ( $new_md5 ne $md5 ) {
            &notice("MD5 verification failed. expected $md5, got $new_md5");
            return;
        }
    }

    rename $loc, "$loc.backup"
      or &notice("Failed to back up $loc: $!.  Aborting")
      and return;
    rename "$loc.upgrade", $loc
      or &notice("Failed to rename $loc.upgrade: $!.  Aborting")
      and return;

    my ( $dir, $file ) = ( $loc =~ m{(.*)/([^/]+)$} );
    if ( -e "$dir/autorun/$file" ) {
        &notice("Updating $dir/autorun/$file");
        unlink "$dir/autorun/$file"
          or &notice("Failed to remove old $file from autorun: $!");
        symlink "../$file", "$dir/autorun/$file"
          or &notice("Failed to create symlink in autorun directory: $!");
    }

    &notice("Download complete.  Reload twirssi with /script load $file");
}

sub load_friends {
    my $fh   = shift;
    my $page = 1;
    my %new_friends;
    eval {
        while (1)
        {
            print $fh "type:debug Loading friends page $page...\n"
              if ( $fh and &debug );
            my $friends = $twit->friends( { page => $page } );
            last unless $friends;
            $new_friends{ $_->{screen_name} } = time foreach @$friends;
            $page++;
            last if @$friends == 0 or $page == 10;
        }
    };

    if ($@) {
        print $fh "type:error Error during friends list update.  Aborted.\n";
        return;
    }

    my ( $added, $removed ) = ( 0, 0 );
    print $fh "type:debug Scanning for new friends...\n" if ( $fh and &debug );
    foreach ( keys %new_friends ) {
        next if exists $friends{$_};
        $friends{$_} = time;
        $added++;
    }

    print $fh "type:debug Scanning for removed friends...\n"
      if ( $fh and &debug );
    foreach ( keys %friends ) {
        next if exists $new_friends{$_};
        delete $friends{$_};
        $removed++;
    }

    return ( $added, $removed );
}

sub get_updates {
    print scalar localtime, " - get_updates starting" if &debug;

    $window =
      Irssi::window_find_name( Irssi::settings_get_str('twitter_window') );
    unless ($window) {
        Irssi::active_win()
          ->print( "Can't find a window named '"
              . Irssi::settings_get_str('twitter_window')
              . "'.  Create it or change the value of twitter_window" );
    }
    unless ($twit) {
        &notice("Not logged in!  Use /twitter_login username pass!");
        return;
    }

    my ( $fh, $filename ) = File::Temp::tempfile();
    my $pid = fork();

    if ($pid) {    # parent
        Irssi::timeout_add_once( 5000, 'monitor_child', [ $filename, 0 ] );
        Irssi::pidwait_add($pid);
    } elsif ( defined $pid ) {    # child
        close STDIN;
        close STDOUT;
        close STDERR;

        my $new_poll = time;

        my $error = 0;
        $error += &do_updates( $fh, $user, $twit );
        foreach ( keys %twits ) {
            next if $_ eq $user;
            $error += &do_updates( $fh, $_, $twits{$_} );
        }

        my ( $added, $removed ) = &load_friends($fh);
        if ( $added + $removed ) {
            print $fh "type:debug %R***%n Friends list updated: ",
              join( ", ",
                sprintf( "%d added",   $added ),
                sprintf( "%d removed", $removed ) ),
              "\n";
        }
        print $fh "__friends__\n";
        foreach ( sort keys %friends ) {
            print $fh "$_ $friends{$_}\n";
        }

        if ($error) {
            print $fh "type:error Update encountered errors.  Aborted\n";
            print $fh $last_poll;
        } else {
            print $fh $new_poll;
        }
        close $fh;
        exit;
    }
    print scalar localtime, " - get_updates ends" if &debug;
}

sub do_updates {
    my ( $fh, $username, $obj ) = @_;

    print scalar localtime, " - Polling for updates for $username" if &debug;
    my $tweets;
    eval {
        $tweets = $obj->friends_timeline(
            { since => HTTP::Date::time2str($last_poll) } );
    };

    if ($@) {
        print $fh "type:error Error during friends_timeline call.  Aborted.\n";
        return 1;
    }

    unless ( ref $tweets ) {
        if ( $obj->can("get_error") ) {
            print $fh "type:error API Error during friends_timeline call: ",
              JSON::Any->jsonToObj( $obj->get_error() ), "  Aborted.\n";
        } else {
            print $fh
              "type:error API Error during friends_timeline call. Aborted.\n";
        }
        return 1;
    }

    foreach my $t ( reverse @$tweets ) {
        my $text = decode_entities( $t->{text} );
        $text =~ s/%/%%/g;
        $text =~ s/(^|\W)\@([-\w]+)/$1%B\@$2%n/g;
        my $reply = "tweet";
        if (    Irssi::settings_get_bool("show_reply_context")
            and $t->{in_reply_to_screen_name} ne $username
            and $t->{in_reply_to_screen_name}
            and not exists $friends{ $t->{in_reply_to_screen_name} } )
        {
            $nicks{ $t->{in_reply_to_screen_name} } = time;
            my $context = $obj->show_status( $t->{in_reply_to_status_id} );
            if ($context) {
                my $ctext = decode_entities( $context->{text} );
                $ctext =~ s/%/%%/g;
                $ctext =~ s/(^|\W)\@([-\w]+)/$1%B\@$2%n/g;
                printf $fh "id:%d account:%s nick:%s type:tweet %s\n",
                  $context->{id}, $username,
                  $context->{user}{screen_name}, $ctext;
                $reply = "reply";
            } else {
                print "Failed to get context from $t->{in_reply_to_screen_name}"
                  if &debug;
            }
        }
        next
          if $t->{user}{screen_name} eq $username
              and not Irssi::settings_get_bool("show_own_tweets");
        printf $fh "id:%d account:%s nick:%s type:%s %s\n",
          $t->{id}, $username, $t->{user}{screen_name}, $reply, $text;
    }

    print scalar localtime, " - Polling for replies" if &debug;
    eval {
        $tweets = $obj->replies( { since => HTTP::Date::time2str($last_poll) } )
          || [];
    };

    if ($@) {
        print $fh "type:error Error during replies call.  Aborted.\n";
        return 1;
    }

    foreach my $t ( reverse @$tweets ) {
        next
          if exists $friends{ $t->{user}{screen_name} };

        my $text = decode_entities( $t->{text} );
        $text =~ s/%/%%/g;
        $text =~ s/(^|\W)\@([-\w]+)/$1%B\@$2%n/g;
        printf $fh "id:%d account:%s nick:%s type:tweet %s\n",
          $t->{id}, $username, $t->{user}{screen_name}, $text;
    }

    print scalar localtime, " - Polling for DMs" if &debug;
    eval {
        $tweets =
          $obj->direct_messages( { since => HTTP::Date::time2str($last_poll) } )
          || [];
    };

    if ($@) {
        print $fh "type:error Error during direct_messages call.  Aborted.\n";
        return 1;
    }

    foreach my $t ( reverse @$tweets ) {
        my $text = decode_entities( $t->{text} );
        $text =~ s/%/%%/g;
        $text =~ s/(^|\W)\@([-\w]+)/$1%B\@$2%n/g;
        printf $fh "id:%d account:%s nick:%s type:dm %s\n",
          $t->{id}, $username, $t->{sender_screen_name}, $text;
    }
    print scalar localtime, " - Done" if &debug;

    return 0;
}

sub monitor_child {
    my ($data)   = @_;
    my $filename = $data->[0];
    my $attempt  = $data->[1];

    print scalar localtime, " - checking child log at $filename ($attempt)"
      if &debug;
    my $new_last_poll;
    if ( open FILE, $filename ) {
        my @lines;
        while (<FILE>) {
            chomp;
            last if /^__friends__/;
            my %meta;
            foreach my $key (qw/id account nick type/) {
                if (s/^$key:(\S+)\s*//) {
                    $meta{$key} = $1;
                }
            }

            next if exists $meta{id} and exists $tweet_cache{ $meta{id} };
            $tweet_cache{ $meta{id} } = time;
            my $account = "";
            if ( $meta{account} ne $user ) {
                $account = "$meta{account}: ";
            }

            my $marker = "";
            if (    $meta{type} ne 'dm'
                and Irssi::settings_get_bool("twirssi_track_replies")
                and $meta{nick}
                and $meta{id} )
            {
                $marker = ( $id_map{__indexes}{ $meta{nick} } + 1 ) % 100;
                $id_map{ lc $meta{nick} }[$marker] = $meta{id};
                $id_map{__indexes}{ $meta{nick} }  = $marker;
                $marker                            = ":$marker";
            }

            if ( $meta{type} eq 'tweet' ) {
                push @lines, "[$account%B\@$meta{nick}%n$marker] $_\n",;
            } elsif ( $meta{type} eq 'reply' ) {
                push @lines, "[$account\\--> %B\@$meta{nick}%n$marker] $_\n",;
            } elsif ( $meta{type} eq 'dm' ) {
                push @lines, "[$account%B\@$meta{nick}%n (%WDM%n)] $_\n",;
            } elsif ( $meta{type} eq 'error' ) {
                push @lines, "ERROR: $_\n";
            } elsif ( $meta{type} eq 'debug' ) {
                print "$_" if &debug,;
            } else {
                print "Unknown line type $meta{type}: $_" if &debug,;
            }
        }

        %friends = ();
        while (<FILE>) {
            if (/^\d+$/) {
                $new_last_poll = $_;
                last;
            }
            my ( $f, $t ) = split ' ', $_;
            $nicks{$f} = $friends{$f} = $t;
        }

        if ($new_last_poll) {
            print "new last_poll = $new_last_poll" if &debug;
            foreach my $line (@lines) {
                chomp $line;
                $window->print( $line, MSGLEVEL_PUBLIC );
                foreach ( $line =~ /\@([-\w]+)/ ) {
                    $nicks{$1} = time;
                }
            }

            close FILE;
            unlink $filename
              or warn "Failed to remove $filename: $!"
              unless &debug;

            # keep enough cached tweets, to make sure we don't show duplicates.
            foreach ( keys %tweet_cache ) {
                next if $tweet_cache{$_} >= $last_poll;
                delete $tweet_cache{$_};
            }
            $last_poll = $new_last_poll;

            # save id_map hash
            if ( keys %id_map
                and my $file =
                Irssi::settings_get_str("twirssi_replies_store") )
            {
                if ( open JSON, ">$file" ) {
                    print JSON JSON::Any->objToJson( \%id_map );
                    close JSON;
                } else {
                    &notice("Failed to write replies to $file: $!");
                }
            }
            return;
        }
    }

    close FILE;

    if ( $attempt < 12 ) {
        Irssi::timeout_add_once( 5000, 'monitor_child',
            [ $filename, $attempt + 1 ] );
    } else {
        &notice("Giving up on polling $filename");
        unlink $filename unless &debug;
    }
}

sub debug {
    return Irssi::settings_get_bool("twirssi_debug");
}

sub notice {
    $window->print( "%R***%n @_", MSGLEVEL_PUBLIC );
}

sub sig_complete {
    my ( $complist, $window, $word, $linestart, $want_space ) = @_;

    if (
        $linestart =~ /^\/twitter_reply(?:_as)?\s*$/
        or ( Irssi::settings_get_bool("twirssi_use_reply_aliases")
            and $linestart =~ /^\/reply(?:_as)?\s*$/ )
      )
    {    # /twitter_reply gets a nick:num
        @$complist = grep /^\Q$word/i, sort keys %{ $id_map{__indexes} };
    }

    # /tweet, /tweet_as, /dm, /dm_as - complete @nicks (and nicks as the first
    # arg to dm)
    if ( $linestart =~ /^\/(?:tweet|dm)/ ) {
        my $prefix = $word =~ s/^@//;
        $prefix = 0 if $linestart eq '/dm' or $linestart eq '/dm_as';
        push @$complist, grep /^\Q$word/i,
          sort { $nicks{$b} <=> $nicks{$a} } keys %nicks;
        @$complist = map { "\@$_" } @$complist if $prefix;
    }
}

Irssi::settings_add_str( "twirssi", "twitter_window",     "twitter" );
Irssi::settings_add_str( "twirssi", "bitlbee_server",     "bitlbee" );
Irssi::settings_add_str( "twirssi", "short_url_provider", "TinyURL" );
Irssi::settings_add_str( "twirssi", "twirssi_location",
    ".irssi/scripts/twirssi.pl" );
Irssi::settings_add_str( "twirssi", "twitter_usernames", undef );
Irssi::settings_add_str( "twirssi", "twitter_passwords", undef );
Irssi::settings_add_str( "twirssi", "twirssi_replies_store",
    ".irssi/scripts/twirssi.json" );
Irssi::settings_add_bool( "twirssi", "tweet_to_away",             0 );
Irssi::settings_add_bool( "twirssi", "show_reply_context",        0 );
Irssi::settings_add_bool( "twirssi", "show_own_tweets",           1 );
Irssi::settings_add_bool( "twirssi", "twirssi_debug",             0 );
Irssi::settings_add_bool( "twirssi", "twirssi_first_run",         1 );
Irssi::settings_add_bool( "twirssi", "twirssi_track_replies",     1 );
Irssi::settings_add_bool( "twirssi", "twirssi_use_reply_aliases", 0 );
$window = Irssi::window_find_name( Irssi::settings_get_str('twitter_window') );

if ($window) {
    Irssi::command_bind( "dm",               "cmd_direct" );
    Irssi::command_bind( "dm_as",            "cmd_direct_as" );
    Irssi::command_bind( "tweet",            "cmd_tweet" );
    Irssi::command_bind( "tweet_as",         "cmd_tweet_as" );
    Irssi::command_bind( "twitter_reply",    "cmd_reply" );
    Irssi::command_bind( "twitter_reply_as", "cmd_reply_as" );
    Irssi::command_bind( "twitter_login",    "cmd_login" );
    Irssi::command_bind( "twitter_logout",   "cmd_logout" );
    Irssi::command_bind( "twitter_switch",   "cmd_switch" );
    Irssi::command_bind( "twirssi_upgrade",  "cmd_upgrade" );
    if ( Irssi::settings_get_bool("twirssi_use_reply_aliases") ) {
        Irssi::command_bind( "reply",    "cmd_reply" );
        Irssi::command_bind( "reply_as", "cmd_reply_as" );
    }
    Irssi::command_bind(
        "twirssi_dump",
        sub {
            print "twits: ", join ", ",
              map { "u: $_->{username}" } values %twits;
            print "friends: ", join ", ", sort keys %friends;
            print "nicks: ",   join ", ", sort keys %nicks;
            print "id_map: ", Dumper \%{ $id_map{__indexes} };
            print "last poll: $last_poll";
        }
    );
    Irssi::command_bind(
        "twirssi_version",
        sub {
            &notice("Twirssi v$VERSION (r$REV); "
                  . "Net::Twitter v$Net::Twitter::VERSION. "
                  . "JSON in use: "
                  . JSON::Any::handler()
                  . ".  See details at http://twirssi.com/" );
        }
    );
    Irssi::command_bind(
        "twitter_friend",
        &gen_cmd(
            "/twitter_friend <username>",
            "create_friend",
            sub { &notice("Following $_[0]"); $nicks{ $_[0] } = time; }
        )
    );
    Irssi::command_bind(
        "twitter_unfriend",
        &gen_cmd(
            "/twitter_unfriend <username>",
            "destroy_friend",
            sub { &notice("Stopped following $_[0]"); delete $nicks{ $_[0] }; }
        )
    );
    Irssi::command_bind( "twitter_updates", "get_updates" );
    Irssi::signal_add_last( 'complete word' => \&sig_complete );

    &notice("  %Y<%C(%B^%C)%N                   TWIRSSI v%R$VERSION%N (r$REV)");
    &notice("   %C(_(\\%N           http://twirssi.com/ for full docs");
    &notice(
        "    %Y||%C `%N Log in with /twitter_login, send updates with /tweet");

    my $file = Irssi::settings_get_str("twirssi_replies_store");
    if ( $file and -r $file ) {
        if ( open( JSON, $file ) ) {
            local $/;
            my $json = <JSON>;
            close JSON;
            eval {
                my $ref = JSON::Any->jsonToObj($json);
                %id_map = %$ref;
                my $num = keys %{ $id_map{__indexes} };
                &notice( sprintf "Loaded old replies from %d contact%s.",
                    $num, ( $num == 1 ? "" : "s" ) );
            };
        } else {
            &notice("Failed to load old replies from $file: $!");
        }
    }

    if ( my $provider = Irssi::settings_get_str("short_url_provider") ) {
        eval "use WWW::Shorten::$provider;";

        if ($@) {
            &notice(
"Failed to load WWW::Shorten::$provider - either clear short_url_provider or install the CPAN module"
            );
        }
    }

    if (    my $autouser = Irssi::settings_get_str("twitter_usernames")
        and my $autopass = Irssi::settings_get_str("twitter_passwords") )
    {
        &cmd_login();
    }

} else {
    Irssi::active_win()
      ->print( "Create a window named "
          . Irssi::settings_get_str('twitter_window')
          . " or change the value of twitter_window.  Then, reload twirssi." );
}

