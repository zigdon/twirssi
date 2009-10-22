use strict;
use Irssi;
use Irssi::Irc;
use HTTP::Date;
use HTML::Entities;
use File::Temp;
use LWP::Simple;
use Data::Dumper;
use Encode;
$Data::Dumper::Indent = 1;

use vars qw($VERSION %IRSSI);

$VERSION = "2.3.0";
%IRSSI = (
    authors     => 'Dan Boger',
    contact     => 'zigdon@gmail.com',
    name        => 'twirssi',
    description => 'Send twitter updates using /tweet.  '
      . 'Can optionally set your bitlbee /away message to same',
    license => 'GNU GPL v2',
    url     => 'http://twirssi.com',
    changed => '$Date: 2009-08-07 01:24:53 -0700 (Fri, 07 Aug 2009) $',
);

my $window;
my $twit;
my %twits;
my $user;
my $defservice;
my $poll;
my $last_poll;
my $last_friends_poll = 0;
my %nicks;
my %friends;
my %tweet_cache;
my %id_map;
my $failwhale  = 0;
my $first_call = 1;
my $child_pid;
my %fix_replies_index;

my %irssi_to_mirc_colors = (
    '%k' => '01',
    '%r' => '05',
    '%g' => '03',
    '%y' => '07',
    '%b' => '02',
    '%m' => '06',
    '%c' => '10',
    '%w' => '15',
    '%K' => '14',
    '%R' => '04',
    '%G' => '09',
    '%Y' => '08',
    '%B' => '12',
    '%M' => '13',
    '%C' => '11',
    '%W' => '00',
);

sub cmd_direct {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    my ( $target, $text ) = split ' ', $data, 2;
    unless ( $target and $text ) {
        &notice("Usage: /dm <nick> <message>");
        return;
    }

    &cmd_direct_as( "$user $data", $server, $win );
}

sub cmd_direct_as {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    my ( $username, $target, $text ) = split ' ', $data, 3;
    unless ( $username and $target and $text ) {
        &notice("Usage: /dm_as <username> <nick> <message>");
        return;
    }

    return unless $username = &valid_username($username);

    eval {
        if ( $twits{$username}
            ->new_direct_message( { user => $target, text => $text } ) )
        {
            &notice("DM sent to $target: $text");
            $nicks{$target} = time;
        } else {
            my $error;
            eval {
                $error = JSON::Any->jsonToObj( $twits{$username}->get_error() );
                $error = $error->{error};
            };
            die $error if $error;
            &notice("DM to $target failed");
        }
    };

    if ($@) {
        &notice("DM caused an error: $@");
        return;
    }
}

sub cmd_retweet {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice("Usage: /retweet <nick[:num]> [comment]");
        return;
    }

    my ( $id, $data ) = split ' ', $data, 2;

    &cmd_retweet_as( "$user $id $data", $server, $win );
}

sub cmd_retweet_as {
    my ( $data, $server, $win ) = @_;

    unless ( Irssi::settings_get_bool("twirssi_track_replies") ) {
        &notice("twirssi_track_replies is required in order to reteet.");
        return;
    }

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    my ( $username, $id, $data ) = split ' ', $data, 3;

    unless ($username) {
        &notice("Usage: /retweet_as <username> <nick[:num]> [comment]");
        return;
    }

    return unless $username = &valid_username($username);

    my $nick;
    $id =~ s/[^\w\d\-:]+//g;
    ( $nick, $id ) = split /:/, $id;
    unless ( exists $id_map{ lc $nick } ) {
        &notice("Can't find a tweet from $nick to retweet!");
        return;
    }

    $id = $id_map{__indexes}{$nick} unless $id;
    unless ( $id_map{ lc $nick }[$id] ) {
        &notice("Can't find a tweet numbered $id from $nick to retweet!");
        return;
    }

    unless ( $id_map{__tweets}{ lc $nick }[$id] ) {
        &notice("The text of this tweet isn't saved, sorry!");
        return;
    }

# Irssi::settings_add_str( "twirssi", "twirssi_retweet_format", 'RT $n: $t ${-- $c$}' );
    my $text = Irssi::settings_get_str("twirssi_retweet_format");
    $text =~ s/\$n/\@$nick/g;
    if ($data) {
        $text =~ s/\${|\$}//g;
        $text =~ s/\$c/$data/;
    } else {
        $text =~ s/\${.*?\$}//;
    }
    $text =~ s/\$t/$id_map{__tweets}{ lc $nick }[$id]/;

    $data = &shorten($text);

    return if &too_long($data);

    my $success = 1;
    eval {
        unless (
            $twits{$username}->update(
                {
                    status => $data,

                    # in_reply_to_status_id => $id_map{ lc $nick }[$id]
                }
            )
          )
        {
            &notice("Update failed");
            $success = 0;
        }
    };
    return unless $success;

    if ($@) {
        &notice("Update caused an error: $@.  Aborted");
        return;
    }

    foreach ( $data =~ /@([-\w]+)/ ) {
        $nicks{$1} = time;
    }

    &notice("Retweet sent");
}

sub cmd_tweet {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice("Usage: /tweet <update>");
        return;
    }

    &cmd_tweet_as( "$user\@$defservice $data", $server, $win );
}

sub cmd_tweet_as {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    $data =~ s/\s\s+/ /g;
    my ( $username, $data ) = split ' ', $data, 2;

    unless ( $username and $data ) {
        &notice("Usage: /tweet_as <username> <update>");
        return;
    }

    return unless $username = &valid_username($username);

    $data = &shorten($data);

    return if &too_long($data);

    my $success = 1;
    eval {
        unless ( $twits{$username}->update($data) )
        {
            &notice("Update failed");
            $success = 0;
        }
    };
    return unless $success;

    if ($@) {
        &notice("Update caused an error: $@.  Aborted.");
        return;
    }

    foreach ( $data =~ /@([-\w]+)/ ) {
        $nicks{$1} = time;
    }

    my $away = &update_away($data);

    &notice( "Update sent" . ( $away ? " (and away msg set)" : "" ) );
}

sub cmd_reply {
    my ( $data, $server, $win ) = @_;

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    unless ($data) {
        &notice("Usage: /reply <nick[:num]> <update>");
        return;
    }

    my ( $id, $data ) = split ' ', $data, 2;
    unless ( $id and $data ) {
        &notice("Usage: /reply <nick[:num]> <update>");
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

    return unless &logged_in($twit);

    $data =~ s/^\s+|\s+$//;
    my ( $username, $id, $data ) = split ' ', $data, 3;

    unless ( $username and $data ) {
        &notice("Usage: /reply_as <username> <nick[:num]> <update>");
        return;
    }

    return unless $username = &valid_username($username);

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

    if ( Irssi::settings_get_bool("twirssi_replies_autonick") ) {

        # remove any @nick at the beginning of the reply, as we'll add it anyway
        $data =~ s/^\s*\@?$nick\s*//;
        $data = "\@$nick " . $data;
    }

    $data = &shorten($data);

    return if &too_long($data);

    my $success = 1;
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
            $success = 0;
        }
    };
    return unless $success;

    if ($@) {
        &notice("Update caused an error: $@.  Aborted");
        return;
    }

    foreach ( $data =~ /@([-\w]+)/ ) {
        $nicks{$1} = time;
    }

    my $away = &update_away($data);

    &notice( "Update sent" . ( $away ? " (and away msg set)" : "" ) );
}

sub gen_cmd {
    my ( $usage_str, $api_name, $post_ref ) = @_;

    return sub {
        my ( $data, $server, $win ) = @_;

        return unless &logged_in($twit);

        $data =~ s/^\s+|\s+$//;
        unless ($data) {
            &notice("Usage: $usage_str");
            return;
        }

        my $success = 1;
        eval {
            unless ( $twit->$api_name($data) )
            {
                &notice("$api_name failed");
                $success = 0;
            }
        };
        return unless $success;

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
    $data = &normalize_username($data);
    if ( exists $twits{$data} ) {
        &notice("Switching to $data");
        $twit = $twits{$data};
        if ( $data =~ /(.*)\@(.*)/ ) {
            $user       = $1;
            $defservice = $2;
        } else {
            &notice("Couldn't figure out what service '$data' is on");
        }
    } else {
        &notice("Unknown user $data");
    }
}

sub cmd_logout {
    my ( $data, $server, $win ) = @_;

    $data =~ s/^\s+|\s+$//g;
    $data = $user unless $data;
    return unless $data = &valid_username($data);

    &notice("Logging out $data...");
    $twits{$data}->end_session();
    delete $twits{$data};
    undef $twit;
    if ( keys %twits ) {
        &cmd_switch( ( keys %twits )[0], $server, $win );
    } else {
        Irssi::timeout_remove($poll) if $poll;
        undef $poll;
    }
}

sub cmd_login {
    my ( $data, $server, $win ) = @_;
    my $pass;
    if ($data) {
        ( $user, $pass ) = split ' ', $data, 2;
        unless ($pass) {
            &notice("usage: /twitter_login <username>[\@<service>] <password>");
            return;
        }
    } elsif ( my $autouser = Irssi::settings_get_str("twitter_usernames")
        and my $autopass = Irssi::settings_get_str("twitter_passwords") )
    {
        my @user = split /\s*,\s*/, $autouser;
        my @pass = split /\s*,\s*/, $autopass;

        # if a password ends with a '\', it was meant to escape the comma, and
        # it should be concatinated with the next one
        my @unescaped;
        while (@pass) {
            my $p = shift @pass;
            while ( $p =~ /\\$/ and @pass ) {
                $p .= "," . shift @pass;
            }
            push @unescaped, $p;
        }

        if ( @user != @unescaped ) {
            &notice("Number of usernames doesn't match "
                  . "the number of passwords - auto-login failed" );
        } else {
            my ( $u, $p );
            while ( @user and @unescaped ) {
                $u = shift @user;
                $p = shift @unescaped;
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

    my $service;
    if ( $user =~ /^(.*)@(twitter|identica)$/ ) {
        ( $user, $service ) = ( $1, $2 );
    } else {
        $service = Irssi::settings_get_str("twirssi_default_service");
    }
    $defservice = $service = ucfirst lc $service;

    eval "use Net::$service";
    if ($@) {
        &notice(
            "Failed to load Net::$service when trying to log in as $user: $@");
        return;
    }

    $twit = "Net::$service"->new(
        username => $user,
        password => $pass,
        source   => "twirssi",
        ssl      => Irssi::settings_get_bool("twirssi_avoid_ssl") ? 0 : 1,
    );

    unless ($twit) {
        &notice("Failed to create Net::$service object!  Aborting.");
        return;
    }

    if ( my $timeout = Irssi::settings_get_int("twitter_timeout")
        and $twit->can('ua') )
    {
        $twit->ua->timeout($timeout);
    }

    unless ( $twit->verify_credentials() ) {
        &notice("Login as $user\@$service failed");

        if ( not Irssi::settings_get_bool("twirssi_avoid_ssl") ) {
            &notice(
                "It's possible you're missing one of the modules required for "
                  . "SSL logins.  Try setting twirssi_avoid_ssl to on.  See "
                  . "http://cpansearch.perl.org/src/GAAS/libwww-perl-5.831/README.SSL "
                  . "for the detailed requirements." );
        }

        $twit = undef;
        if ( keys %twits ) {
            &cmd_switch( ( keys %twits )[0], $server, $win );
        }
        return;
    }

    if ($twit) {
        my $rate_limit = $twit->rate_limit_status();
        if ( $rate_limit and $rate_limit->{remaining_hits} < 1 ) {
            &notice(
                "Rate limit exceeded, try again after $rate_limit->{reset_time}"
            );
            $twit = undef;
            return;
        }

        $twits{"$user\@$service"} = $twit;
        Irssi::timeout_remove($poll) if $poll;
        $poll = Irssi::timeout_add( &get_poll_time * 1000, \&get_updates, "" );
        &notice("Logged in as $user\@$service, loading friends list...");
        &load_friends();
        &notice( "loaded friends: ", scalar keys %friends );
        if ( Irssi::settings_get_bool("twirssi_first_run") ) {
            Irssi::settings_set_bool( "twirssi_first_run", 0 );
        }
        %nicks = %friends;
        $nicks{$user} = 0;
        return 1;
    } else {
        &notice("Login failed");
    }
}

sub cmd_add_follow {
    my ( $data, $server, $win ) = @_;

    unless ($data) {
        &notice("Usage: /twitter_add_follow_extra <username>");
        return;
    }

    $data =~ s/^\s+|\s+$//;
    $data =~ s/^\@//;
    $data = lc $data;

    if ( exists $id_map{__fixreplies}{"$user\@$defservice"}{$data} ) {
        &notice("Already following all replies by \@$data");
        return;
    }

    $id_map{__fixreplies}{"$user\@$defservice"}{$data} = 1;
    &notice("Will now follow all replies by \@$data");
}

sub cmd_del_follow {
    my ( $data, $server, $win ) = @_;

    unless ($data) {
        &notice("Usage: /twitter_del_follow_extra <username>");
        return;
    }

    $data =~ s/^\s+|\s+$//;
    $data =~ s/^\@//;
    $data = lc $data;

    unless ( exists $id_map{__fixreplies}{"$user\@$defservice"}{$data} ) {
        &notice("Wasn't following all replies by \@$data");
        return;
    }

    delete $id_map{__fixreplies}{"$user\@$defservice"}{$data};
    &notice("Will no longer follow all replies by \@$data");
}

sub cmd_list_follow {
    my ( $data, $server, $win ) = @_;

    my $found = 0;
    foreach my $suser ( sort keys %{ $id_map{__fixreplies} } ) {
        my $frusers;
        foreach my $fruser ( sort keys %{ $id_map{__fixreplies}{$suser} } ) {
            $frusers = $frusers ? "$frusers, $fruser" : $fruser;
        }
        if ($frusers) {
            $found = 1;
            &notice("Following all replies as \@$suser: $frusers");
        }
    }

    unless ($found) {
        &notice("Not following all replies by anyone");
    }
}

sub cmd_add_search {
    my ( $data, $server, $win ) = @_;

    unless ( $twit and $twit->can('search') ) {
        &notice("ERROR: Your version of Net::Twitter ($Net::Twitter::VERSION) "
              . "doesn't support searches." );
        return;
    }

    $data =~ s/^\s+|\s+$//;
    $data = lc $data;

    unless ($data) {
        &notice("Usage: /twitter_subscribe <topic>");
        return;
    }

    if ( exists $id_map{__searches}{"$user\@$defservice"}{$data} ) {
        &notice("Already had a subscription for '$data'");
        return;
    }

    $id_map{__searches}{"$user\@$defservice"}{$data} = 1;
    &notice("Added subscription for '$data'");
}

sub cmd_del_search {
    my ( $data, $server, $win ) = @_;

    unless ( $twit and $twit->can('search') ) {
        &notice("ERROR: Your version of Net::Twitter ($Net::Twitter::VERSION) "
              . "doesn't support searches." );
        return;
    }
    $data =~ s/^\s+|\s+$//;
    $data = lc $data;

    unless ($data) {
        &notice("Usage: /twitter_unsubscribe <topic>");
        return;
    }

    unless ( exists $id_map{__searches}{"$user\@$defservice"}{$data} ) {
        &notice("No subscription found for '$data'");
        return;
    }

    delete $id_map{__searches}{"$user\@$defservice"}{$data};
    &notice("Removed subscription for '$data'");
}

sub cmd_list_search {
    my ( $data, $server, $win ) = @_;

    my $found = 0;
    foreach my $suser ( sort keys %{ $id_map{__searches} } ) {
        my $topics;
        foreach my $topic ( sort keys %{ $id_map{__searches}{$suser} } ) {
            $topics = $topics ? "$topics, $topic" : $topic;
        }
        if ($topics) {
            $found = 1;
            &notice("Search subscriptions for \@$suser: $topics");
        }
    }

    unless ($found) {
        &notice("No search subscriptions set up");
    }
}

sub cmd_upgrade {
    my ( $data, $server, $win ) = @_;

    my $loc = Irssi::settings_get_str("twirssi_location");
    unless ( -w $loc ) {
        &notice( "$loc isn't writable, can't upgrade." .
                 "  Perhaps you need to /set twirssi_location?"
        );
        return;
    }

    my $md5;
    unless ( $data or Irssi::settings_get_bool("twirssi_upgrade_beta") ) {
        eval { use Digest::MD5; };

        if ($@) {
            &notice( "Failed to load Digest::MD5." . 
                     "  Try '/twirssi_upgrade nomd5' to skip MD5 verification"
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
            &notice( "Failed to read $loc." .
                     "  Check that /set twirssi_location is set to the correct location."
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

    my $URL =
      Irssi::settings_get_bool("twirssi_upgrade_beta")
      ? "http://github.com/zigdon/twirssi/raw/master/twirssi.pl"
      : "http://twirssi.com/twirssi.pl";
    &notice("Downloading twirssi from $URL");
    LWP::Simple::getstore( $URL, "$loc.upgrade" );

    unless ( -s "$loc.upgrade" ) {
        &notice("Failed to save $loc.upgrade."
              . "  Check that /set twirssi_location is set to the correct location."
        );
        return;
    }

    unless ( $data or Irssi::settings_get_bool("twirssi_upgrade_beta") ) {
        unless ( open( NEW, "$loc.upgrade" ) ) {
            &notice("Failed to read $loc.upgrade."
                  . "  Check that /set twirssi_location is set to the correct location."
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
    my $cursor = -1;
    my $page = 1;
    my %new_friends;
    eval {
        while ($page < 11 and $cursor ne "0")
        {
            print $fh "type:debug Loading friends page $page...\n"
              if ( $fh and &debug );
            my $friends;
            if (ref $twit =~ /^Net::Twitter/) {
                $friends = $twit->friends( { cursor => $cursor } );
                last unless $friends;
                $cursor = $friends->{next_cursor};
                $friends = $friends->{users};
            } else {
                $friends = $twit->friends( { page => $page } );
                last unless $friends;
            }
            $new_friends{ $_->{screen_name} } = time foreach @$friends;
            $page++;
        }
    };

    if ($@) {
        print $fh "type:debug Error during friends list update.  Aborted.\n";
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

    return unless &logged_in($twit);

    my ( $fh, $filename ) = File::Temp::tempfile();
    binmode( $fh, ":utf8" );
    $child_pid = fork();

    if ($child_pid) {    # parent
        Irssi::timeout_add_once( 5000, 'monitor_child',
            [ "$filename.done", 0 ] );
        Irssi::pidwait_add($child_pid);
    } elsif ( defined $child_pid ) {    # child
        close STDIN;
        close STDOUT;
        close STDERR;

        my $new_poll = time;

        my $error = 0;
        my %context_cache;
        foreach ( keys %twits ) {
            $error++ unless &do_updates( $fh, $_, $twits{$_}, \%context_cache );

            if ( $id_map{__fixreplies}{$_} ) {
                my @frusers = sort keys %{ $id_map{__fixreplies}{$_} };

                $error++
                  unless &get_timeline( $fh, $frusers[ $fix_replies_index{$_} ],
                    $_, $twits{$_}, \%context_cache );

                $fix_replies_index{$_}++;
                $fix_replies_index{$_} = 0
                  if $fix_replies_index{$_} >= @frusers;
                print $fh "id:$fix_replies_index{$_} ",
                          "account:$_ type:fix_replies_index\n";
            }
        }

        print $fh "__friends__\n";
        if (
            time - $last_friends_poll >
            Irssi::settings_get_int('twitter_friends_poll') )
        {
            print $fh "__updated ", time, "\n";
            my ( $added, $removed ) = &load_friends($fh);
            if ( $added + $removed ) {
                print $fh "type:debug %R***%n Friends list updated: ",
                  join( ", ",
                    sprintf( "%d added",   $added ),
                    sprintf( "%d removed", $removed ) ),
                  "\n";
            }
        }

        foreach ( sort keys %friends ) {
            print $fh "$_ $friends{$_}\n";
        }

        if ($error) {
            print $fh "type:debug Update encountered errors.  Aborted\n";
            print $fh "-- $last_poll";
        } else {
            print $fh "-- $new_poll";
        }
        close $fh;
        rename $filename, "$filename.done";
        exit;
    } else {
        &ccrap("Failed to fork for updating: $!");
    }
    print scalar localtime, " - get_updates ends" if &debug;
}

sub do_updates {
    my ( $fh, $username, $obj, $cache ) = @_;

    my $rate_limit = $obj->rate_limit_status();
    if ( $rate_limit and $rate_limit->{remaining_hits} < 1 ) {
        &notice("Rate limit exceeded for $username");
        return undef;
    }

    print scalar localtime, " - Polling for updates for $username" if &debug;
    my $tweets;
    my $new_poll_id = 0;
    eval {
        if ( $id_map{__last_id}{$username}{timeline} )
        {
            $tweets = $obj->friends_timeline( { count => 100 } );
        } else {
            $tweets = $obj->friends_timeline();
        }
    };

    if ($@) {
        print $fh "type:debug Error during friends_timeline call: Aborted.\n";
        print $fh "type:debug : $_\n" foreach split /\n/, Dumper($@);
        return undef;
    }

    unless ( ref $tweets ) {
        if ( $obj->can("get_error") ) {
            my $error = "Unknown error";
            eval { $error = JSON::Any->jsonToObj( $obj->get_error() ) };
            unless ($@) { $error = $obj->get_error() }
            print $fh
              "type:debug API Error during friends_timeline call: Aborted\n";
            print $fh "type:debug : $_\n" foreach split /\n/, Dumper($error);

        } else {
            print $fh
              "type:debug API Error during friends_timeline call. Aborted.\n";
        }
        return undef;
    }

    foreach my $t ( reverse @$tweets ) {
        my $text = decode_entities( $t->{text} );
        $text =~ s/[\n\r]/ /g;
        my $reply = "tweet";
        if (    Irssi::settings_get_bool("show_reply_context")
            and $t->{in_reply_to_screen_name} ne $username
            and $t->{in_reply_to_screen_name}
            and not exists $friends{ $t->{in_reply_to_screen_name} } )
        {
            $nicks{ $t->{in_reply_to_screen_name} } = time;
            my $context;
            unless ( $cache->{ $t->{in_reply_to_status_id} } ) {
                eval {
                    $cache->{ $t->{in_reply_to_status_id} } =
                      $obj->show_status( $t->{in_reply_to_status_id} );
                };

            }
            $context = $cache->{ $t->{in_reply_to_status_id} };

            if ($context) {
                my $ctext = decode_entities( $context->{text} );
                $ctext =~ s/[\n\r]/ /g;
                if ( $context->{truncated} and ref($obj) ne 'Net::Identica' ) {
                    $ctext .=
                        " -- http://twitter.com/$context->{user}{screen_name}"
                      . "/status/$context->{id}";
                }
                printf $fh "id:%s account:%s nick:%s type:tweet %s\n",
                  $context->{id}, $username,
                  $context->{user}{screen_name}, $ctext;
                $reply = "reply";
            }
        }
        next
          if $t->{user}{screen_name} eq $username
              and not Irssi::settings_get_bool("show_own_tweets");
        if ( $t->{truncated} and ref($obj) ne 'Net::Identica' ) {
            $text .= " -- http://twitter.com/$t->{user}{screen_name}"
              . "/status/$t->{id}";
        }
        printf $fh "id:%s account:%s nick:%s type:%s %s\n",
          $t->{id}, $username, $t->{user}{screen_name}, $reply, $text;
        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
    }
    printf $fh "id:%s account:%s type:last_id timeline\n",
      $new_poll_id, $username;

    print scalar localtime, " - Polling for replies since ",
      $id_map{__last_id}{$username}{reply}
      if &debug;
    $new_poll_id = 0;
    eval {
        if ( $id_map{__last_id}{$username}{reply} )
        {
            $tweets = $obj->replies(
                { since_id => $id_map{__last_id}{$username}{reply} } )
              || [];
        } else {
            $tweets = $obj->replies() || [];
        }
    };

    if ($@) {
        print $fh "type:debug Error during replies call.  Aborted.\n";
        return undef;
    }

    foreach my $t ( reverse @$tweets ) {
        next
          if exists $friends{ $t->{user}{screen_name} };

        my $text = decode_entities( $t->{text} );
        $text =~ s/[\n\r]/ /g;
        if ( $t->{truncated} ) {
            $text .= " -- http://twitter.com/$t->{user}{screen_name}"
              . "/status/$t->{id}";
        }
        printf $fh "id:%s account:%s nick:%s type:tweet %s\n",
          $t->{id}, $username, $t->{user}{screen_name}, $text;
        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
    }
    printf $fh "id:%s account:%s type:last_id reply\n", $new_poll_id, $username;

    print scalar localtime, " - Polling for DMs" if &debug;
    $new_poll_id = 0;
    eval {
        if ( $id_map{__last_id}{$username}{dm} )
        {
            $tweets = $obj->direct_messages(
                { since_id => $id_map{__last_id}{$username}{dm} } )
              || [];
        } else {
            $tweets = $obj->direct_messages() || [];
        }
    };

    if ($@) {
        print $fh "type:debug Error during direct_messages call.  Aborted.\n";
        return undef;
    }

    foreach my $t ( reverse @$tweets ) {
        my $text = decode_entities( $t->{text} );
        $text =~ s/[\n\r]/ /g;
        printf $fh "id:%s account:%s nick:%s type:dm %s\n",
          $t->{id}, $username, $t->{sender_screen_name}, $text;
        $new_poll_id = $t->{id} if $new_poll_id < $t->{id};
    }
    printf $fh "id:%s account:%s type:last_id dm\n", $new_poll_id, $username;

    print scalar localtime, " - Polling for subscriptions" if &debug;
    if ( $obj->can('search') and $id_map{__searches}{$username} ) {
        my $search;
        foreach my $topic ( sort keys %{ $id_map{__searches}{$username} } ) {
            print $fh "type:debug searching for $topic since ",
              "$id_map{__searches}{$username}{$topic}\n";
            eval {
                $search = $obj->search(
                    {
                        q        => $topic,
                        since_id => $id_map{__searches}{$username}{$topic}
                    }
                );
            };

            if ($@) {
                print $fh
                  "type:debug Error during search($topic) call.  Aborted.\n";
                return undef;
            }

            unless ( $search->{max_id} ) {
                print $fh "type:debug Invalid search results when searching",
                  " for $topic. Aborted.\n";
                return undef;
            }

            $id_map{__searches}{$username}{$topic} = $search->{max_id};
            printf $fh "id:%s account:%s type:searchid topic:%s\n",
              $search->{max_id}, $username, $topic;

            foreach my $t ( reverse @{ $search->{results} } ) {
                my $text = decode_entities( $t->{text} );
                $text =~ s/[\n\r]/ /g;
                printf $fh "id:%s account:%s nick:%s type:search topic:%s %s\n",
                  $t->{id}, $username, $t->{from_user}, $topic, $text;
                $new_poll_id = $t->{id}
                  if not $new_poll_id
                      or $t->{id} < $new_poll_id;
            }
        }
    }

    print scalar localtime, " - Done" if &debug;

    return 1;
}

sub get_timeline {
    my ( $fh, $target, $username, $obj, $cache ) = @_;
    my $tweets;
    my $last_id = $id_map{__last_id}{$username}{$target};

    print $fh "type:debug get_timeline(" .
              "$fix_replies_index{$username}=$target > $last_id) started." .
              "  username = $username\n";
    eval {
        $tweets = $obj->user_timeline(
            {
                id => $target,
                (   
                    $last_id ? (since_id => $last_id) : ()
                ),
            }
        );
    };

    if ($@) {
        print $fh
          "type:debug Error during user_timeline($target) call: Aborted.\n";
        print $fh "type:debug : $_\n" foreach split /\n/, Dumper($@);
        return undef;
    }

    unless ($tweets) {
        print $fh
          "type:debug user_timeline($target) call returned undef!  Aborted\n";
        return 1;
    }

    foreach my $t ( reverse @$tweets ) {
        my $text = decode_entities( $t->{text} );
        $text =~ s/[\n\r]/ /g;
        my $reply = "tweet";
        if (    Irssi::settings_get_bool("show_reply_context")
            and $t->{in_reply_to_screen_name} ne $username
            and $t->{in_reply_to_screen_name}
            and not exists $friends{ $t->{in_reply_to_screen_name} } )
        {
            $nicks{ $t->{in_reply_to_screen_name} } = time;
            my $context;
            unless ( $cache->{ $t->{in_reply_to_status_id} } ) {
                eval {
                    $cache->{ $t->{in_reply_to_status_id} } =
                      $obj->show_status( $t->{in_reply_to_status_id} );
                };

            }
            $context = $cache->{ $t->{in_reply_to_status_id} };

            if ($context) {
                my $ctext = decode_entities( $context->{text} );
                $ctext =~ s/[\n\r]/ /g;
                if ( $context->{truncated} and ref($obj) ne 'Net::Identica' ) {
                    $ctext .=
                        " -- http://twitter.com/$context->{user}{screen_name}"
                      . "/status/$context->{id}";
                }
                printf $fh "id:%s account:%s nick:%s type:tweet %s\n",
                  $context->{id}, $username,
                  $context->{user}{screen_name}, $ctext;
                $reply = "reply";
            }
        }
        if ( $t->{truncated} and ref($obj) ne 'Net::Identica' ) {
            $text .= " -- http://twitter.com/$t->{user}{screen_name}"
              . "/status/$t->{id}";
        }
        printf $fh "id:%s account:%s nick:%s type:%s %s\n",
          $t->{id}, $username, $t->{user}{screen_name}, $reply, $text;
        $last_id = $t->{id} if $last_id < $t->{id};
    }
    printf $fh "id:%s account:%s type:last_id_fixreplies %s\n",
        $last_id, $username, $target;

    return 1;
}

sub monitor_child {
    my ($data)   = @_;
    my $filename = $data->[0];
    my $attempt  = $data->[1];

    print scalar localtime, " - checking child log at $filename ($attempt)"
      if &debug;
    my ($new_last_poll);

    # first time we run we don't want to print out *everything*, so we just
    # pretend

    if ( open FILE, $filename ) {
        binmode FILE, ":utf8";
        my @lines;
        my %new_cache;
        while (<FILE>) {
            last if /^__friends__/;
            unless (/\n$/) {    # skip partial lines
                                # print "Skipping partial line: $_" if &debug;
                next;
            }
            chomp;
            my $hilight = 0;
            my %meta;

            foreach my $key (qw/id account nick type topic/) {
                if (s/^$key:(\S+)\s*//) {
                    $meta{$key} = $1;
                }
            }

            if ( $meta{type} and $meta{type} eq 'fix_replies_index' ) {
                $fix_replies_index{ $meta{account} } = $meta{id};
                print "fix_replies_index for $meta{account} set to $meta{id}"
                  if &debug;
                next;
            }

            if ( not $meta{type} or $meta{type} !~ /searchid|last_id/ ) {
                if ( exists $meta{id} and exists $new_cache{ $meta{id} } ) {
                    next;
                }

                $new_cache{ $meta{id} } = time;

                if ( exists $meta{id} and exists $tweet_cache{ $meta{id} } ) {
                    next;
                }
            }

            my $account = "";
            $meta{account} =~ s/\@(\w+)$//;
            $meta{service} = $1;
            if (
                lc $meta{service} eq
                lc Irssi::settings_get_str("twirssi_default_service") )
            {
                $account = "$meta{account}: "
                  if lc "$meta{account}\@$meta{service}" ne lc
                      "$user\@$defservice";
            } else {
                $account = "$meta{account}\@$meta{service}: ";
            }

            my $marker = "";
            if (    $meta{type} ne 'dm'
                and Irssi::settings_get_bool("twirssi_track_replies")
                and $meta{nick}
                and $meta{id} )
            {
                $marker = ( $id_map{__indexes}{ $meta{nick} } + 1 ) % 100;
                $id_map{ lc $meta{nick} }[$marker]           = $meta{id};
                $id_map{__indexes}{ $meta{nick} }            = $marker;
                $id_map{__tweets}{ lc $meta{nick} }[$marker] = $_;
                $marker                                      = ":$marker";
            }

            my $hilight_color =
              $irssi_to_mirc_colors{ Irssi::settings_get_str("hilight_color") };
            my $nick = "\@$meta{account}";
            if ( $_ =~ /\Q$nick\E(?:\W|$)/i
                and Irssi::settings_get_bool("twirssi_hilights") )
            {
                $meta{nick} = "\cC$hilight_color$meta{nick}\cO";
                $hilight = MSGLEVEL_HILIGHT;
            }

            if ( $meta{type} =~ /tweet|reply/ ) {
                push @lines,
                  [
                    ( MSGLEVEL_PUBLIC | $hilight ),
                    $meta{type}, $account, $meta{nick}, $marker, $_
                  ];
            } elsif ( $meta{type} eq 'search' ) {
                push @lines,
                  [
                    ( MSGLEVEL_PUBLIC | $hilight ),
                    $meta{type}, $account, $meta{topic},
                    $meta{nick}, $marker,  $_
                  ];
                if (
                    exists $id_map{__searches}{ $meta{account} }{ $meta{topic} }
                    and $meta{id} >
                    $id_map{__searches}{ $meta{account} }{ $meta{topic} } )
                {
                    $id_map{__searches}{ $meta{account} }{ $meta{topic} } =
                      $meta{id};
                }
            } elsif ( $meta{type} eq 'dm' ) {
                push @lines,
                  [
                    ( MSGLEVEL_MSGS | $hilight ),
                    $meta{type}, $account, $meta{nick}, $_
                  ];
            } elsif ( $meta{type} eq 'searchid' ) {
                print "Search '$meta{topic}' returned id $meta{id}" if &debug;
                if (
                    not
                    exists $id_map{__searches}{ $meta{account} }{ $meta{topic} }
                    or $meta{id} >=
                    $id_map{__searches}{ $meta{account} }{ $meta{topic} } )
                {
                    $id_map{__searches}{ $meta{account} }{ $meta{topic} } =
                      $meta{id};
                } elsif (&debug) {
                    print "Search '$meta{topic}' returned invalid id $meta{id}";
                }
            } elsif ( $meta{type} eq 'last_id' ) {
                $id_map{__last_id}{"$meta{account}\@$meta{service}"}{$_} =
                  $meta{id}
                  if $id_map{__last_id}{"$meta{account}\@$meta{service}"}{$_} <
                      $meta{id};
            } elsif ( $meta{type} eq 'last_id_fixreplies' ) {
                $id_map{__last_id}{"$meta{account}\@$meta{service}"}{$_} =
                  $meta{id}
                  if $id_map{__last_id}{"$meta{account}\@$meta{service}"}{$_} <
                      $meta{id};
            } elsif ( $meta{type} eq 'error' ) {
                push @lines, [ MSGLEVEL_MSGS, $_ ];
            } elsif ( $meta{type} eq 'debug' ) {
                print "$_" if &debug,;
            } else {
                print "Unknown line type $meta{type}: $_" if &debug,;
            }
        }

        %friends = ();
        while (<FILE>) {
            if (/^__updated (\d+)$/) {
                $last_friends_poll = $1;
                print "Friend list updated" if &debug;
                next;
            }

            if (/^-- (\d+)$/) {
                $new_last_poll = $1;
                if ( $new_last_poll >= $last_poll ) {
                    last;
                } else {
                    print "Impossible!  ",
                      "new_last_poll=$new_last_poll < last_poll=$last_poll!"
                      if &debug;
                    undef $new_last_poll;
                    next;
                }
            }
            my ( $f, $t ) = split ' ', $_;
            $nicks{$f} = $friends{$f} = $t;
        }

        if ($new_last_poll) {
            print "new last_poll    = $new_last_poll" if &debug;
            print "new last_poll_id = ", Dumper( $id_map{__last_id} ) if &debug;
            if ($first_call) {
                print "First call, not printing updates" if &debug;
            } else {
                foreach my $line (@lines) {
                    $window->printformat(
                        $line->[0],
                        "twirssi_" . $line->[1],
                        @$line[ 2 .. $#$line - 1 ],
                        &hilight( $line->[-1] )
                    );
                }
            }

            close FILE;
            unlink $filename
              or warn "Failed to remove $filename: $!"
              unless &debug;

            # commit the pending cache lines to the actual cache, now that
            # we've printed our output
            %tweet_cache = ( %tweet_cache, %new_cache );

            # keep enough cached tweets, to make sure we don't show duplicates.
            foreach ( keys %tweet_cache ) {
                next if $tweet_cache{$_} >= $last_poll - 3600;
                delete $tweet_cache{$_};
            }
            $last_poll = $new_last_poll;

            # make sure the pid is removed from the waitpid list
            Irssi::pidwait_remove($child_pid);

            # and that we don't leave any zombies behind, somehow
            wait();

            # save id_map hash
            if ( keys %id_map
                and my $file =
                Irssi::settings_get_str("twirssi_replies_store") )
            {
                if ( open JSON, ">$file" ) {
                    print JSON JSON::Any->objToJson( \%id_map );
                    close JSON;
                } else {
                    &ccrap("Failed to write replies to $file: $!");
                }
            }
            $failwhale  = 0;
            $first_call = 0;
            return;
        }
    }

    close FILE;

    if ( $attempt < 24 ) {
        Irssi::timeout_add_once( 5000, 'monitor_child',
            [ $filename, $attempt + 1 ] );
    } else {
        print "Giving up on polling $filename" if &debug;
        Irssi::pidwait_remove($child_pid);
        wait();
        unlink $filename unless &debug;

        return unless Irssi::settings_get_bool("twirssi_notify_timeouts");

        my $since;
        my @time = localtime($last_poll);
        if ( time - $last_poll < 24 * 60 * 60 ) {
            $since = sprintf( "%d:%02d", @time[ 2, 1 ] );
        } else {
            $since = scalar localtime($last_poll);
        }

        if ( not $failwhale and time - $last_poll > 60 * 60 ) {
            foreach my $whale (
                q{     v  v        v},
                q{     |  |  v     |  v},
                q{     | .-, |     |  |},
                q{  .--./ /  |  _.---.| },
                q{   '-. (__..-"       \\},
                q{      \\          a    |},
                q{       ',.__.   ,__.-'/},
                q{         '--/_.'----'`}
              )
            {
                &ccrap($whale);
            }
            $failwhale = 1;
        }

        if ( time - $last_poll < 600 ) {
            &ccrap("Haven't been able to get updated tweets since $since");
        }
    }
}

sub debug {
    return Irssi::settings_get_bool("twirssi_debug");
}

sub notice {
    $window->print( "%R***%n @_", MSGLEVEL_PUBLIC );
}

sub ccrap {
    $window->print( "%R***%n @_", MSGLEVEL_CLIENTCRAP );
}

sub update_away {
    my $data = shift;

    if (    Irssi::settings_get_bool("tweet_to_away")
        and $data !~ /\@\w/
        and $data !~ /^[dD] / )
    {
        my $server =
          Irssi::server_find_tag( Irssi::settings_get_str("bitlbee_server") );
        if ($server) {
            $server->send_raw("away :$data");
            return 1;
        } else {
            &ccrap( "Can't find bitlbee server.",
                "Update bitlbee_server or disable tweet_to_away" );
            return 0;
        }
    }

    return 0;
}

sub too_long {
    my $data    = shift;
    my $noalert = shift;

    if ( length $data > 140 ) {
        &notice( "Tweet too long (" . length($data) . " characters) - aborted" )
          unless $noalert;
        return 1;
    }

    return 0;
}

sub valid_username {
    my $username = shift;

    $username = &normalize_username($username);

    unless ( exists $twits{$username} ) {
        &notice("Unknown username $username");
        return undef;
    }

    return $username;
}

sub logged_in {
    my $obj = shift;
    unless ($obj) {
        &notice("Not logged in!  Use /twitter_login username pass!");
        return 0;
    }

    return 1;
}

sub sig_complete {
    my ( $complist, $window, $word, $linestart, $want_space ) = @_;

    if (
        $linestart =~ /^\/(?:retweet|twitter_reply)(?:_as)?\s*$/
        or ( Irssi::settings_get_bool("twirssi_use_reply_aliases")
            and $linestart =~ /^\/reply(?:_as)?\s*$/ )
      )
    {    # /twitter_reply gets a nick:num
        $word =~ s/^@//;
        @$complist = map { "$_:$id_map{__indexes}{$_}" }
          sort { $nicks{$b} <=> $nicks{$a} }
          grep /^\Q$word/i,
          keys %{ $id_map{__indexes} };
    }

    if ( $linestart =~ /^\/(twitter_unfriend|twitter_add_follow_extra|twitter_del_follow_extra)\s*$/ )
    {    # /twitter_unfriend gets a nick
        $word =~ s/^@//;
        push @$complist, grep /^\Q$word/i,
          sort { $nicks{$b} <=> $nicks{$a} } keys %nicks;
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

sub event_send_text {
    my ( $line, $server, $win ) = @_;
    my $awin = Irssi::active_win();

    # if the window where we got our text was the twitter window, and the user
    # wants to be lazy, tweet away!
    if ( ( $awin->get_active_name() eq $window->{name} )
        and Irssi::settings_get_bool("tweet_window_input") )
    {
        &cmd_tweet( $line, $server, $win );
    }
}

sub get_poll_time {
    my $poll = Irssi::settings_get_int("twitter_poll_interval");
    return $poll if $poll >= 60;
    return 60;
}

sub hilight {
    my $text = shift;

    if ( Irssi::settings_get_str("twirssi_nick_color") ) {
        my $c = Irssi::settings_get_str("twirssi_nick_color");
        $c = $irssi_to_mirc_colors{$c};
        $text =~ s/(^|\W)\@([-\w]+)/$1\cC$c\@$2\cO/g if $c;
    }
    if ( Irssi::settings_get_str("twirssi_topic_color") ) {
        my $c = Irssi::settings_get_str("twirssi_topic_color");
        $c = $irssi_to_mirc_colors{$c};
        $text =~ s/(^|\W)(\#|\!)([-\w]+)/$1\cC$c$2$3\cO/g if $c;
    }
    $text =~ s/[\n\r]/ /g;

    return $text;
}

sub shorten {
    my $data = shift;

    my $provider = Irssi::settings_get_str("short_url_provider");
    if (
        (
            Irssi::settings_get_bool("twirssi_always_shorten")
            or &too_long( $data, 1 )
        )
        and $provider
      )
    {
        my @args;
        if ( $provider eq 'Bitly' ) {
            @args[ 1, 2 ] = split ',',
              Irssi::settings_get_str("short_url_args"), 2;
            unless ( @args == 3 ) {
                &ccrap(
                    "WWW::Shorten::Bitly requires a username and API key.",
                    "Set short_url_args to username,API_key or change your",
                    "short_url_provider."
                );
                return decode "utf8", $data;
            }
        }

        foreach my $url ( $data =~ /(https?:\/\/\S+[\w\/])/g ) {
            eval {
                $args[0] = $url;
                my $short = makeashorterlink(@args);
                if ($short) {
                    $data =~ s/\Q$url/$short/g;
                } else {
                    &notice("Failed to shorten $url!");
                }
            };
        }
    }

    return decode "utf8", $data;
}

sub normalize_username {
    my $user = shift;

    my ( $username, $service ) = split /\@/, $user, 2;
    if ($service) {
        $service = ucfirst lc $service;
    } else {
        $service =
          ucfirst lc Irssi::settings_get_str("twirssi_default_service");
        unless ( exists $twits{"$username\@$service"} ) {
            $service = undef;
            foreach my $t ( sort keys %twits ) {
                next unless $t =~ /^\Q$username\E\@(Twitter|Identica)/;
                $service = $1;
                last;
            }

            unless ($service) {
                &notice("Can't find a logged in user '$user'");
            }
        }
    }

    return "$username\@$service";
}

Irssi::signal_add( "send text", "event_send_text" );

Irssi::theme_register(
    [
        'twirssi_tweet',  '[$0%B@$1%n$2] $3',
        'twirssi_search', '[$0%r$1%n:%B@$2%n$3] $4',
        'twirssi_reply',  '[$0\--> %B@$1%n$2] $3',
        'twirssi_dm',     '[$0%r@$1%n (%WDM%n)] $2',
        'twirssi_error',  'ERROR: $0',
    ]
);

Irssi::settings_add_int( "twirssi", "twitter_poll_interval", 300 );
Irssi::settings_add_str( "twirssi", "twitter_window",          "twitter" );
Irssi::settings_add_str( "twirssi", "bitlbee_server",          "bitlbee" );
Irssi::settings_add_str( "twirssi", "short_url_provider",      "TinyURL" );
Irssi::settings_add_str( "twirssi", "short_url_args",          undef );
Irssi::settings_add_str( "twirssi", "twitter_usernames",       undef );
Irssi::settings_add_str( "twirssi", "twitter_passwords",       undef );
Irssi::settings_add_str( "twirssi", "twirssi_default_service", "Twitter" );
Irssi::settings_add_str( "twirssi", "twirssi_nick_color",      "%B" );
Irssi::settings_add_str( "twirssi", "twirssi_topic_color",     "%r" );
Irssi::settings_add_str( "twirssi", "twirssi_retweet_format",
    'RT $n: "$t" ${-- $c$}' );
Irssi::settings_add_str( "twirssi", "twirssi_location",
    ".irssi/scripts/twirssi.pl" );
Irssi::settings_add_str( "twirssi", "twirssi_replies_store",
    ".irssi/scripts/twirssi.json" );

Irssi::settings_add_int( "twirssi", "twitter_friends_poll", 600 );
Irssi::settings_add_int( "twirssi", "twitter_timeout",      30 );

Irssi::settings_add_bool( "twirssi", "twirssi_upgrade_beta",      0 );
Irssi::settings_add_bool( "twirssi", "tweet_to_away",             0 );
Irssi::settings_add_bool( "twirssi", "show_reply_context",        0 );
Irssi::settings_add_bool( "twirssi", "show_own_tweets",           1 );
Irssi::settings_add_bool( "twirssi", "twirssi_debug",             0 );
Irssi::settings_add_bool( "twirssi", "twirssi_first_run",         1 );
Irssi::settings_add_bool( "twirssi", "twirssi_track_replies",     1 );
Irssi::settings_add_bool( "twirssi", "twirssi_replies_autonick",  1 );
Irssi::settings_add_bool( "twirssi", "twirssi_use_reply_aliases", 0 );
Irssi::settings_add_bool( "twirssi", "twirssi_notify_timeouts",   1 );
Irssi::settings_add_bool( "twirssi", "twirssi_hilights",          1 );
Irssi::settings_add_bool( "twirssi", "twirssi_always_shorten",    0 );
Irssi::settings_add_bool( "twirssi", "tweet_window_input",        0 );
Irssi::settings_add_bool( "twirssi", "twirssi_avoid_ssl",         0 );

$last_poll = time - &get_poll_time;
$window = Irssi::window_find_name( Irssi::settings_get_str('twitter_window') );
if ( !$window ) {
    Irssi::active_win()
      ->print( "Couldn't find a window named '"
          . Irssi::settings_get_str('twitter_window')
          . "', trying to create it." );
    $window =
      Irssi::Windowitem::window_create(
        Irssi::settings_get_str('twitter_window'), 1 );
    $window->set_name( Irssi::settings_get_str('twitter_window') );
}

if ($window) {
    Irssi::command_bind( "dm",                         "cmd_direct" );
    Irssi::command_bind( "dm_as",                      "cmd_direct_as" );
    Irssi::command_bind( "tweet",                      "cmd_tweet" );
    Irssi::command_bind( "tweet_as",                   "cmd_tweet_as" );
    Irssi::command_bind( "retweet",                    "cmd_retweet" );
    Irssi::command_bind( "retweet_as",                 "cmd_retweet_as" );
    Irssi::command_bind( "twitter_reply",              "cmd_reply" );
    Irssi::command_bind( "twitter_reply_as",           "cmd_reply_as" );
    Irssi::command_bind( "twitter_login",              "cmd_login" );
    Irssi::command_bind( "twitter_logout",             "cmd_logout" );
    Irssi::command_bind( "twitter_switch",             "cmd_switch" );
    Irssi::command_bind( "twitter_subscribe",          "cmd_add_search" );
    Irssi::command_bind( "twitter_unsubscribe",        "cmd_del_search" );
    Irssi::command_bind( "twitter_list_subscriptions", "cmd_list_search" );
    Irssi::command_bind( "twirssi_upgrade",            "cmd_upgrade" );
    Irssi::command_bind( "twitter_updates",            "get_updates" );
    Irssi::command_bind( "twitter_add_follow_extra",   "cmd_add_follow" );
    Irssi::command_bind( "twitter_del_follow_extra",   "cmd_del_follow" );
    Irssi::command_bind( "twitter_list_follow_extra",  "cmd_list_follow" );
    Irssi::command_bind( "bitlbee_away",               "update_away" );
    if ( Irssi::settings_get_bool("twirssi_use_reply_aliases") ) {
        Irssi::command_bind( "reply",    "cmd_reply" );
        Irssi::command_bind( "reply_as", "cmd_reply_as" );
    }
    Irssi::command_bind(
        "twirssi_dump",
        sub {
            print "twits: ", join ", ",
              map { "u: $_->{username}\@" . ref($_) } values %twits;
            print "selected: $user\@$defservice";
            print "friends: ", join ", ", sort keys %friends;
            print "nicks: ",   join ", ", sort keys %nicks;
            print "searches: ", Dumper \%{ $id_map{__searches} };
            print "last poll: $last_poll";
            if ( open DUMP, ">/tmp/twirssi.cache.txt" ) {
                print DUMP Dumper \%tweet_cache;
                close DUMP;
                print "cache written out to /tmp/twirssi.cache.txt";
            }
        }
    );
    Irssi::command_bind(
        "twirssi_version",
        sub {
            &notice(
                "Twirssi v$VERSION; "
                  . (
                    $Net::Twitter::VERSION
                    ? "Net::Twitter v$Net::Twitter::VERSION. "
                    : ""
                  )
                  . (
                    $Net::Identica::VERSION
                    ? "Net::Identica v$Net::Identica::VERSION. "
                    : ""
                  )
                  . "JSON in use: "
                  . JSON::Any::handler()
                  . ".  See details at http://twirssi.com/"
            );
        }
    );
    Irssi::command_bind(
        "twitter_follow",
        &gen_cmd(
            "/twitter_follow <username>",
            "create_friend",
            sub { &notice("Following $_[0]"); $nicks{ $_[0] } = time; }
        )
    );
    Irssi::command_bind(
        "twitter_unfollow",
        &gen_cmd(
            "/twitter_unfriend <username>",
            "destroy_friend",
            sub { &notice("Stopped following $_[0]"); delete $nicks{ $_[0] }; }
        )
    );
    Irssi::command_bind(
        "twitter_device_updates",
        &gen_cmd(
            "/twitter_device_updates none|im|sms",
            "update_delivery_device",
            sub { &notice("Device updated to $_[0]"); }
        )
    );
    Irssi::command_bind(
        "twitter_block",
        &gen_cmd(
            "/twitter_block <username>",
            "create_block",
            sub { &notice("Blocked $_[0]"); }
        )
    );
    Irssi::command_bind(
        "twitter_unblock",
        &gen_cmd(
            "/twitter_unblock <username>",
            "destroy_block",
            sub { &notice("Unblock $_[0]"); }
        )
    );
    Irssi::signal_add_last( 'complete word' => \&sig_complete );

    &notice("  %Y<%C(%B^%C)%N                   TWIRSSI v%R$VERSION%N");
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
                &cmd_list_search;
                &cmd_list_follow;
            };
        } else {
            &notice("Failed to load old replies from $file: $!");
        }
    }

    if ( my $provider = Irssi::settings_get_str("short_url_provider") ) {
        &notice("Loading WWW::Shorten::$provider...");
        eval "use WWW::Shorten::$provider;";

        if ($@) {
            &notice(
                "Failed to load WWW::Shorten::$provider - either clear",
                "short_url_provider or install the CPAN module"
            );
        }
    }

    if (    my $autouser = Irssi::settings_get_str("twitter_usernames")
        and my $autopass = Irssi::settings_get_str("twitter_passwords") )
    {
        &cmd_login();
        &get_updates;
    }

} else {
    Irssi::active_win()
      ->print( "Create a window named "
          . Irssi::settings_get_str('twitter_window')
          . " or change the value of twitter_window.  Then, reload twirssi." );
}

# vim: set sts=4 expandtab:
