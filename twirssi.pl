use strict;
use Irssi;
use Irssi::Irc;
use Net::Twitter;
use HTTP::Date;
use HTML::Entities;
use File::Temp;

use vars qw($VERSION %IRSSI);
use constant { DEBUG => 0 };

$VERSION = "1.1";
my ($REV) = '$Rev: 302 $' =~ /(\d+)/;
%IRSSI   = (
    authors     => 'Dan Boger',
    contact     => 'zigdon@gmail.com',
    name        => 'twirssi',
    description => 'Send twitter updates using /tweet.  '
      . 'Can optionally set your bitlbee /away message to same',
    license => 'GNU GPL v2',
    url     => 'http://tinyurl.com/twirssi',
    changed => 'Mon Dec  1 15:36:01 PST 2008',
);

my $window;
my $twit;
my $user;
my $poll;
my %nicks;
my %friends;
my $last_poll = time - 300;

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

    unless ( $twit->new_direct_message( { user => $target, text => $text } ) ) {
        &notice("DM to $target failed");
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

    foreach my $url ( $data =~ /(https?:\/\/\S+[\w\/])/g ) {
        eval { my $short = makeashorterlink($url); $data =~ s/\Q$url/$short/g; };
    }

    unless ( $twit->update($data) ) {
        &notice("Update failed");
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

        unless ( $twit->$api_name($data) ) {
            &notice("$api_name failed");
            return;
        }

        &$post_ref($data) if $post_ref;
      }
}

sub cmd_login {
    my ( $data, $server, $win ) = @_;
    my $pass;
    ( $user, $pass ) = split ' ', $data, 2;

    %friends = %nicks = ();

    $twit = Net::Twitter->new(
        username => $user,
        password => $pass,
        source   => "twirssi"
    );

    unless ( $twit->verify_credentials() ) {
        &notice("Login failed");
        $twit = undef;
        return;
    }

    if ($twit) {
        Irssi::timeout_remove($poll) if $poll;
        $poll = Irssi::timeout_add( 300 * 1000, \&get_updates, "" );
        &notice("Logged in as $user, loading friends list...");
        &load_friends;
        &notice( "loaded friends: ", scalar keys %nicks );
        $nicks{$user} = 0;
        &get_updates;
    } else {
        &notice("Login failed");
    }
}

sub load_friends {
    my $page = 1;
    my %new_friends;
    while (1) {
        my $friends = $twit->friends( { page => $page } );
        last unless $friends;
        $new_friends{ $_->{screen_name} } = $nicks{ $_->{screen_name} } = time
          foreach @$friends;
        $page++;
        last if @$friends == 0 or $page == 10;
        $friends = $twit->friends( page => $page );
    }

    foreach (keys %new_friends) {
      next if exists $friends{$_};
      $friends{$_} = time;
    }

    foreach (keys %friends) {
      delete $friends{$_} unless exists $new_friends{$_};
    }
}

sub get_updates {
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
        Irssi::timeout_add_once( 5000, 'monitor_child', [$filename] );
    } elsif ( defined $pid ) {    # child
        close STDIN;
        close STDOUT;
        close STDERR;

        my $new_poll = time;

        print scalar localtime, " - Polling for updates" if DEBUG;
        my $tweets = $twit->friends_timeline(
            { since => HTTP::Date::time2str($last_poll) } )
          || [];
        foreach my $t ( reverse @$tweets ) {
            my $text = decode_entities( $t->{text} );
            $text =~ s/%/%%/g;
            $text =~ s/(^|\W)\@([-\w]+)/$1%B\@$2%n/g;
            my $prefix = "";
            if (    Irssi::settings_get_bool("show_reply_context")
                and $t->{in_reply_to_screen_name} ne $user
                and $t->{in_reply_to_screen_name}
                and not exists $friends{ $t->{in_reply_to_screen_name} } )
            {
                $nicks{ $t->{in_reply_to_screen_name} } = time;
                my $context = $twit->show_status( $t->{in_reply_to_status_id} );
                if ($context) {
                    my $ctext = decode_entities( $context->{text} );
                    $ctext =~ s/%/%%/g;
                    $ctext =~ s/(^|\W)\@([-\w]+)/$1%B\@$2%n/g;
                    printf $fh "[%%B\@%s%%n] %s\n",
                      $context->{user}{screen_name}, $ctext;
                    $prefix = "\--> ";
                }
            }
            next
              if $t->{user}{screen_name} eq $user
                  and not Irssi::settings_get_bool("show_own_tweets");
            printf $fh "%s[%%B\@%s%%n] %s\n", $prefix, $t->{user}{screen_name},
              $text;
        }

        print scalar localtime, " - Polling for replies" if DEBUG;
        $tweets =
          $twit->replies( { since => HTTP::Date::time2str($last_poll) } )
          || [];
        foreach my $t ( reverse @$tweets ) {
            next
              if exists $friends{ $t->{user}{screen_name} };

            my $text = decode_entities( $t->{text} );
            $text =~ s/%/%%/g;
            $text =~ s/(^|\W)\@([-\w]+)/$1%B\@$2%n/g;
            printf $fh "[%%B\@%s%%n] %s\n", $t->{user}{screen_name}, $text;
        }

        print scalar localtime, " - Polling for DMs" if DEBUG;
        $tweets = $twit->direct_messages(
            { since => HTTP::Date::time2str($last_poll) } )
          || [];
        foreach my $t ( reverse @$tweets ) {
            my $text = decode_entities( $t->{text} );
            $text =~ s/%/%%/g;
            $text =~ s/(^|\W)\@([-\w]+)/$1%B\@$2%n/g;
            printf $fh "[%%B\@%s%%n (%%WDM%%n)] %s\n", $t->{sender_screen_name},
              $text;
        }
        print scalar localtime, " - Done" if DEBUG;
        print $fh "__friends__\n";
        &load_friends;
        foreach (sort keys %friends) {
          print $fh "$_ $friends{$_}\n";
        }
        print $fh $new_poll;
        close $fh;
        exit;
    }
}

sub monitor_child {
    my $data     = shift;
    my $filename = $data->[0];

    print scalar localtime, " - checking child log at $filename" if DEBUG;
    if ( open FILE, $filename ) {
        my @lines;
        while (<FILE>) {
          chomp;
          last if /^__friends__/;
          push @lines, $_ unless /^__friends__/;
        }

        %friends = ();
        while (<FILE>) {
          if (/^\d+$/) {
            $last_poll = $_;
            last;
          }
          my ($f, $t) = split ' ', $_;
          $friends{$f} = $t;
        }

        print "new last_poll = $last_poll" if DEBUG;
        foreach my $line (@lines) {
            chomp $line;
            $window->print( $line, MSGLEVEL_PUBLIC );
            foreach ( $line =~ /\@([-\w]+)/ ) {
                $nicks{$1} = time;
            }
        }

        close FILE;
        unlink $filename or warn "Failed to remove $filename: $!";
        return;
    }

    Irssi::timeout_add_once( 5000, 'monitor_child', [$filename] );
}

sub notice {
    $window->print( "%R***%n @_", MSGLEVEL_PUBLIC );
}

sub sig_complete {
    my ( $complist, $window, $word, $linestart, $want_space ) = @_;

    return unless $linestart =~ /^\/(?:tweet|dm)/;
    return if $linestart eq '/tweet' and $word !~ s/^@//;
    push @$complist, grep /^\Q$word/i,
      sort { $nicks{$b} <=> $nicks{$a} } keys %nicks;
    @$complist = map { "\@$_" } @$complist if $linestart eq '/tweet';
}

Irssi::settings_add_str( "twirssi", "twitter_window",     "twitter" );
Irssi::settings_add_str( "twirssi", "bitlbee_server",     "bitlbee" );
Irssi::settings_add_str( "twirssi", "short_url_provider", "TinyURL" );
Irssi::settings_add_bool( "twirssi", "tweet_to_away",      0 );
Irssi::settings_add_bool( "twirssi", "show_reply_context", 0 );
Irssi::settings_add_bool( "twirssi", "show_own_tweets",    1 );
$window = Irssi::window_find_name( Irssi::settings_get_str('twitter_window') );
if ($window) {
    Irssi::command_bind( "dm",            "cmd_direct" );
    Irssi::command_bind( "tweet",         "cmd_tweet" );
    Irssi::command_bind( "twitter_login", "cmd_login" );
    Irssi::command_bind(
        "twirssi_version",
        sub {
            &notice(
                "Twirssi v$VERSION (r$REV).  See details at http://tinyurl.com/twirssi"
            );
        }
    );
    Irssi::command_bind(
        "twitter_friend",
        &gen_cmd(
            "/twitter_friend <username>",
            "create_friend",
            sub { &notice("Following $_[0]"); $nicks{$_[0]} = time; }
        )
    );
    Irssi::command_bind(
        "twitter_unfriend",
        &gen_cmd(
            "/twitter_unfriend <username>",
            "destroy_friend",
            sub { &notice("Stopped following $_[0]"); delete $nicks{$_[0]}; }
        )
    );
    Irssi::command_bind( "twitter_updates", "get_updates" );
    Irssi::signal_add_last( 'complete word' => \&sig_complete );

    &notice("  %Y<%C(%B^%C)%N                   TWIRSSI v%R$VERSION%N (r$REV)");
    &notice("   %C(_(\\%N        http://tinyurl.com/twirssi for full docs");
    &notice( "    %Y||%C `%N Log in with /twitter_login, send updates with /tweet");

    if ( my $provider = Irssi::settings_get_str("short_url_provider") ) {
        eval "use WWW::Shorten::$provider;";

        if ($@) {
            &notice(
"Failed to load WWW::Shorten::$provider - either clear short_url_provider or install the CPAN module"
            );
        }
    }
} else {
    Irssi::active_win()
      ->print( "Create a window named "
          . Irssi::settings_get_str('twitter_window')
          . " or change the value of twitter_window.  Then, reload twirssi." );
}

