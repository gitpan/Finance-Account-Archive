#!/usr/bin/perl -w
# -*- perl -*-

package Finance::Account::Archive;

use DBI;
use POSIX;
use strict;

our $verbose = 0;

our $VERSION = '1.0';

sub logmsg {
    if ($verbose) {
        my @msg = @_;
        chomp @msg;
        my ($pkg,  $fname, $line, undef) = caller(0);
        my (undef, undef,  undef, $sub)  = caller(1);
        printf STDERR "[%50s:%-5d] {%-50s} ", $fname, $line, $sub;
        print STDERR @msg, "\n";
    }
}

sub new {
    my ($class, %opts) = @_;

    my $self = {
                driver   => "Pg", # PostgreSQL by default; "mysql" also works
                username => defined $opts{driver} && $opts{driver} eq "mysql" ? "root" : "",
                password => "",
                dbname   => "finances",
                %opts,
                dbh      => undef
               };
    bless $self, $class;

    my $data_source = "dbi:" . $self->{driver} . ":dbname=" . $self->{dbname};
    logmsg "connecting to $data_source";

    $self->{dbh} = DBI->connect($data_source, $self->{username}, $self->{password}); 
    unless ($self->{dbh}) {
        # print "DBI error: $DBI::errstr\n";
        $self->create_database;
        # We can't access it immediately, so wait for a moment:
        sleep(2);
    }

    $self;
}

sub DESTROY {
    my $self = shift;
    $self->disconnect;
}

sub disconnect {
    my $self = shift;
    logmsg "disconnecting from database ...";
    
    $self->{dbh} && $self->{dbh}->disconnect;
}

sub create_database {
    my $self = shift;
    
    logmsg "creating database ...";
    
    # reconnect to default DB
    my $dbh = DBI->connect("dbi:" . $self->{driver} . ":", 
                           $self->{username}, 
                           $self->{password}); 
    
    $dbh->do("create database " . $self->{dbname});
    $dbh->disconnect();

    $self->{dbh} = DBI->connect("dbi:" . $self->{driver} . ":dbname=" . $self->{dbname}, 
                                $self->{username}, 
                                $self->{password});
    
    $self->{dbh}->do("create table entry ( name TEXT, balance FLOAT4, date DATE )");
}

sub has_entry {
    my $self = shift;
    my %opts = @_;
    
    my $sql = "select count(*) from entry " .
      "where entry.name = '$opts{name}' and entry.date = ";
    $sql .= defined $opts{date} ? "'$opts{date}'" : "'now'::date";
    
    logmsg "sql: $sql";

    my $sth = $self->{dbh}->prepare($sql);
    $sth->execute();

    my $count = $sth->fetchrow_array();
    logmsg "#entries: $count";
    $count;
}

sub add_entry {
    my $self = shift;
    my %opts = @_;
    
    unless ($self->has_entry(name => $opts{name}, date => $opts{date})) {
        logmsg "adding entry...";
        # undefined date implies today ("now")
        my $sql = "insert into entry ( name, balance, date ) " .
          "VALUES ( '$opts{name}', $opts{balance}, ";
        $sql .= (defined $opts{date} ? "'$opts{date}'" : "'now'::date");
        $sql .= " )";
        logmsg "sql: $sql\n";
        $self->{dbh}->do($sql);
    }

    # $self->display_all_entries() if $verbose;
}

sub delete_entry {
    my $self = shift;
    my %opts = @_;
    
    logmsg "deleting entry...";
    my $sql = ("delete from entry " .
               "where name = '$opts{name}' and " .
               "balance = '$opts{balance}' and " .
               "date = '$opts{date}'");
    logmsg "sql: $sql\n";
    $self->{dbh}->do($sql);

    # $self->display_all_entries() if $verbose;
}


sub _nonempty {
    local $_ = shift;
    defined($_) && $_ ne "";
}

sub update_entry {
    my $self = shift;
    my %opts = @_;

    logmsg "updating entry...";
    while (my ($k, $v) = each %opts) {
        logmsg "    \$opts{$k} => " . (defined($v) ? $v : "undef") . "\n";
    }

    my $set   = join ", ", map { "$_ = '$opts{\"new$_\"}'"} grep { _nonempty($opts{"new$_"}) } qw(name balance);
    my $where = defined($opts{date}) ? ("date = '" . $opts{date} . "'") : "date = 'now'::date";

    $where = join " and ", $where, map { "$_ = '$opts{\"$_\"}'" }
      grep { _nonempty($opts{$_}) } qw(name balance);

    my $sql   = "update entry set $set where $where";
    
    logmsg "sql: $sql\n";
    $self->{dbh}->do($sql);

    # $self->display_all_entries() if $verbose;
}

sub display_all_entries {
    my $self = shift;
    
    logmsg "getting contents of entry table:\n";
    my $sth = $self->{dbh}->prepare("select * from entry");
    $sth->execute();

    my @row;
    while (@row = $sth->fetchrow_array()) {
        printf "%-25s | %10s | %10s\n", @row;
    }
}

sub destroy_database {
    my $self = shift;
    my ($class, %opts) = @_;

    # sporadic timing issues, so give it a chance to finish whatever it's doing:
    sleep(1);

    logmsg "removing DB ...";

    # a different handle:
    my $dbh = DBI->connect("dbi:" . $self->{driver} . ":", $self->{username}, $self->{password}); 
    $dbh->do("drop database " . $self->{dbname});
    $dbh->disconnect();
    $dbh = undef;
}

sub get_entries {
    my $self = shift;
    my %opts = @_;

    # logmsg "getting entries ...";

    my $sql = "select * from entry ";

    my @conditions = ();
    if (defined $opts{lowerbound}) {
        # PostgreSQL wants time intervals to be quoted; MySQL does not:
        $opts{lowerbound} = "'$opts{lowerbound}'" if $self->{driver} eq "Pg";
        push @conditions, "current_timestamp - interval $opts{lowerbound} <= entry.date";
    }
    if (defined $opts{upperbound}) {
        $opts{upperbound} = "'$opts{upperbound}'" if $self->{driver} eq "Pg";
        push @conditions, "current_timestamp - interval $opts{upperbound} >= entry.date";
    }
    if (defined $opts{name}) {
        push @conditions, "name = '$opts{name}'";
    }    
    if (scalar @conditions) {
        $sql .= " where " . join(" and ", @conditions);
    }
    
    $sql .= " order by " . (defined $opts{order} ? $opts{order} : "date");
    $sql .= " limit $opts{limit}" if defined $opts{limit};
    
    logmsg "sql: $sql\n";

    my $sth = $self->{dbh}->prepare($sql);
    $sth->execute();

    my @entries = ();
    while (my @row = $sth->fetchrow_array()) {
        # logmsg join(", ", @row);
        push @entries, [ @row ];
    }
    
    $sth->finish();

    @entries;
}

# Prints a prompt, and returns the response (chomped)
sub _ask {
    my $prompt = $_[0] ? "$_[0] " : "";
    print "$prompt>> ";
    my $response = <>;
    chomp $response;
    $response;
}

# Prints account info, formatted. Accepts strings only.
sub _printfmtd {
    my ($fmt, $maxwidth, @info) = @_;
    printf $fmt, $info[0], $maxwidth, $info[1], $info[2], $info[3];
}

sub run {
    my $self = shift;

    my $lastname = undef;
    my $lastdate = undef;

    my %names = ();

    my $HDR_FMT = "| %5s | %-*s | %-10s | %-10s |\n";
    my $BNR_FMT = "+=%-5s=+=%-*s=+=%-10s=+=%-10s=+\n";
    my $ROW_FMT = "| %5d | %-*s | %-10.2f | %-10s |\n";

    while (1) {
        my @data = $self->get_entries(order => "date, name");

        my $maxwidth = 0;
        for (map { $_->[0] } @data) {
            my $len = length($_);
            $maxwidth = $len if $len > $maxwidth;
            $names{$_} = 1;
        }

        $maxwidth = 15 if $maxwidth == 0;

        _printfmtd($BNR_FMT, $maxwidth, "=" x 5, "=" x $maxwidth, "=" x 10,  "=" x 10);
        _printfmtd($HDR_FMT, $maxwidth, "INDEX", "ACCOUNT",       "BALANCE", "DATE");
        _printfmtd($BNR_FMT, $maxwidth, "=" x 5, "=" x $maxwidth, "=" x 10,  "=" x 10);
        for (0 .. $#data) {
            _printfmtd($ROW_FMT, $maxwidth, $_, $data[$_]->[0], $data[$_]->[1], $data[$_]->[2]);
        }
        _printfmtd($BNR_FMT, $maxwidth, "=" x 5, "=" x $maxwidth, "=" x 10,  "=" x 10);

        print "\n";
        print "(a) add data\n";
        print "(m) modify data\n";
        print "(d) delete data\n";
        print "(n) add account name\n";
        print "(q) quit\n";

        my $answer = _ask();
        
        if ($answer eq "q") {
            last;
        }
        elsif ($answer eq "a") {
            if (scalar keys %names == 0) {
                print "please enter some account names first\n";
                next;
            }
            
            print "names:\n";
            my @names = sort keys %names;
            for (0 .. $#names) {
                printf "%5d %s\n", $_, $names[$_];
            }
            
            print "<ENTER> for $lastname " if defined $lastname;
            
            my $namestr = _ask("name (0 .. $#names)");
            logmsg "namestr: $namestr\n";
            
            my $name    = $namestr == "" ? $lastname : $names[int($namestr)];
            logmsg "name: $name\n";
        
            $lastname = $name;

            print "yyyy-mm-dd -- one date\n";
            print "yyyy-mm-dd .. yyyy-mm-dd -- range of dates\n";
            
            my $dtstr = _ask("date");

            $dtstr =~ s/^(\d{4}\-\d\d\-\d\d)//;            
            my $date = $1;
            my $end  = $dtstr =~ /(\d{4}\-\d\d\-\d\d)/ ? $1 : $date;
            
            while (1) {
                my $balance = _ask("$date balance");
                $balance =~ s/^.*?([\d\.]*)/$1/g;

                if ($balance ne "") {
                    logmsg "\$self->add_entry(name => $name, balance => $balance, date => $date)\n";
                    $self->add_entry(name => $name, balance => $balance, date => $date);
                }

                last if $date eq $end;

                # go to the next day:
                my ($y, $m, $d) = split('-', $date);
                $date = POSIX::strftime("%Y-%m-%d", 0, 0, 0, $d + 1, $m - 1, $y - 1900);
            }
        }
        elsif ($answer eq "d") {
            print "format:\n";
            print "    NUM            -- one entry\n";
            print "    NUM1,NUM2,NUM3 -- list of entries\n";
            print "    NUM1 .. NUM2   -- range of entries\n";
            print "the above can be combined\n";
            
            my $indexstr = _ask("index (0 .. $#data)");
            
            my @indices = ();
            my @inds    = split(/\s*,\s*/, $indexstr);

            logmsg "indices: " . join(", ", @inds);
            
            for (@inds) {
                logmsg "processing index '$_'\n";
                if (/^(\d+)\s*\.\.\s*(\d+)$/) {
                    my ($start, $end) = ($1, $2);
                    logmsg "start: $start\n";
                    logmsg "end  : $end\n";
                    push @indices, map { $_ } $start .. $end;
                }
                else {
                    push @indices, $_;
                }
                logmsg "indices: " . join(", ", @indices);
            }

            logmsg "indices: " . join(", ", @indices);

            for (@indices) {
                _printfmtd($ROW_FMT, $maxwidth, $_, $data[$_]->[0], $data[$_]->[1], $data[$_]->[2]);
            }
            
            my $ans = _ask("confirm (y/n)");
            
            if ($ans =~ /^y/i) {
                for (@indices) {
                    # _printfmtd($ROW_FMT, $maxwidth, $_, $data[$_]->[0], $data[$_]->[1], $data[$_]->[2]);
                    logmsg "\$self->delete_entry(name => $data[$_]->[0], balance => $data[$_]->[1], date => $data[$_]->[2])\n";
                    $self->delete_entry(name => $data[$_]->[0], balance => $data[$_]->[1], date => $data[$_]->[2]);
                }
            }
        }
        elsif ($answer eq "m") {
            my $index = int(_ask("index (0 .. $#data)"));

            _printfmtd($ROW_FMT, $maxwidth, $index, $data[$index]->[0], $data[$index]->[1], $data[$index]->[2]);

            print "(empty string for no change)\n";
            my $name = _ask("name");
            
            print "(empty string for no change)\n";
            my $balance = _ask("balance");
            
            # strip the monetary unit:
            $balance =~ s/^.*?([\d\.]*)/$1/g;
            
            next if $name eq "" && $balance eq "";
            
            logmsg("\$self->update_entry(name => $data[$index]->[0], " .
                   "balance => $data[$index]->[1], " .
                   "date => $data[$index]->[2], " .
                   "newname => $name, " .
                   "newbalance => $balance)\n");
            
            $self->update_entry(name       => $data[$index]->[0], 
                                balance    => $data[$index]->[1], 
                                date       => $data[$index]->[2],
                                newname    => $name,
                                newbalance => $balance);
        }
        elsif ($answer eq "n") {
            my $name = _ask("name");
            $names{$name} = 1;
        }
        else {
            print "invalid response: $answer\n";
        }
    }
}


1;

__END__

=head1 NAME

Finance::Account::Archive - Storage of account balances

=head1 SYNOPSIS

  use Finance::Account::Archive;
  $archive = Finance::Account::Archive->new;
  $archive->display_all_entries;
  $archive->add_entry(name => "Checking", balance => 789.12);
  @entries = $archive->get_entries(name => "Savings");

  $archive->run;

=head1 DESCRIPTION

This module is for storing bank account information in a database. This
information consists of an account name, a balance, and a date.

=over 4

=item B<new>(... parameters ...)

Creates a new archive (database), or connects to the existing one. The valid
parameters, which are passed as a hash, are:

=over 4

=item B<driver>

The database driver, which defaults to "Pg", for PostgreSQL. MySQL ("mysql") has
also been successfully used. See C<DBI> for supported drivers.

=item B<username>

The user name for connecting to the database. This defaults to "root" if the
driver is "mysql", or an empty string otherwise.

=item B<password>

The password for connecting to the database. This defaults to an empty string.

=item B<dbname>

The name of the database, which defaults to "finances".

=back

=item B<disconnect>

Disconnects from the database, which is done automatically when the
Finance::Account::Archive instance is destroyed.

=item B<create_database>

Creates the database and adds the "entry" table.

Creates the database and adds the "entry" table.

=item B<has_entry>(name => $name, date => $date)

Returns whether an entry exists for the given name and date. If the date is not
given, the current date is used.

=item B<add_entry>(name => $name, balance => $balance, date => $date)

Adds the given entry, if an existing one for the name and date does not exist.

=item B<delete_entry>(name => $name, balance => $balance, date => $date)

Deletes the given entry, if it exists. C<balance> and C<date> are used only if
they are defined.

=item B<update_entry>(... parameters ...)

Updates the given entry, if it exists. The valid parameters, passed as a hash:

=over 4

=item B<name>

The current name of the existing entry.

=item B<balance>

The current balance of the existing entry.

=item B<date>

The date of the existing entry. If not defined, it is assumed to refer to the
current date.

=item B<newname>

The new name of the entry.

=item B<newbalance>

The new balance of the entry.

=back

=item B<display_all_entries>

Dumps the entire entry table, formatted.

=item B<destroy_database>

Removes the database.

=item B<get_entries>(... parameters ...)

Queries for entries, using the following parameters:

=over 4

=item B<name>

The account name.

=item B<order>

The order in which to return the entries found.

=item B<limit>

The maximum number of entries to return.

=item B<lowerbound>

The earliest date to query.

=item B<upperbound>

The latest date to query.

=back

=item B<run>

Interactively runs against the database, allowing the user to add, modify and
delete data, and to add an account name.

=back

=head2 Class Variables

=over 4

=item verbose

Setting this to a non-zero value results in debugging output.

=back

=head1 CAVEATS

(Verbatim from Finance::Bank::LloydsTSB) This is code for B<online banking>,
and that means B<your money>, and that means B<BE CAREFUL>. You are encouraged,
nay, expected, to audit the source of this module yourself to reassure yourself
that I am not doing anything untoward with your banking data. This software is
useful to me, but is provided under B<NO GUARANTEE>, explicit or implied.

=head1 AUTHOR

Jeff Pace C<jpace@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2005 by Jeff Pace.

This library is free software; you may redistribute it and/or modify it under
the same terms as Perl itself.

=cut
