
package Loadbars::Main;

use strict;
use warnings;

use SDL;
use SDL::App;
use SDL::Rect;
use SDL::Event;

use SDL::Surface;
use SDL::Font;

use Time::HiRes qw(usleep gettimeofday);

use Proc::ProcessTable;

use threads;
use threads::shared;

use Loadbars::Constants;

$| = 1;

my %PIDS : shared;
my %AVGSTATS : shared;
my %CPUSTATS : shared;
my %MEMSTATS : shared;
my %MEMSTATS_HAS : shared;
#my %NETSTATS : shared;
#my %NETSTATS_HAS : shared;

# Global configuration hash
my %C : shared;
# Global configuration hash for internal settings (not configurable)
my %I : shared;

# Setting defaults
%C = (
    average => 15,
    barwidth => 35,
    extended => 0,
    factor => 1,
    height => 230,
    maxwidth => 1280, 
    samples => 1000,
    showcores => 0,
    showmem => 0,
    showtext => 1,
    showtexthost => 0,
    sshopts => '',
);

%I = (
    cpuregexp => 'cpu',
    showtextoff => 0,
);

# Quick n dirty helpers
sub say (@) { print "$_\n" for @_; return undef }
sub newline () { say ''; return undef }
sub debugsay (@) { say "Loadbars::DEBUG: $_" for @_; return undef }
sub sum (@) { my $sum = 0; $sum += $_ for @_; return $sum }
sub null ($) { defined $_[0] ? $_[0] : 0 }
sub notnull ($) {  $_[0] != 0 ? $_[0] : 1 }
sub set_showcores_regexp () { $I{cpuregexp} = $C{showcores} ? 'cpu' : 'cpu ' }
sub error ($) { die shift, "\n" }
sub display_info_no_nl ($) { print "==> " . (shift) . ' ' }
sub display_info ($) { say "==> " . shift }
sub display_warn ($) { say "!!! " . shift }

sub trim (\$) { 
    my $str = shift; 

    $$str =~ s/^[\s\t]+//;
    $$str =~ s/[\s\t]+$//;

    return undef;
}

sub percentage ($$) {
    my ($total, $part) = @_;

    return int (null($part) / notnull ( null($total) / 100));
}

sub norm ($) {
    my $n = shift;

    return $n if $C{factor} != 1;
    return $n > 100 ? 100 : ( $n < 0 ? 0 : $n );
}

sub parse_cpu_line ($) {
    my $line = shift;
    my ($name, %load);

    ( $name, @load{qw(user nice system idle iowait irq softirq steal guest)} ) =
      split ' ', $line;

    # Not all kernels support this
    $load{steal} = 0 unless defined $load{steal};
    $load{guest} = 0 unless defined $load{guest};

    $load{TOTAL} =
      sum @load{qw(user nice system idle iowait irq softirq steal guest)};

    return ($name, \%load);
}

sub read_config () {
    return unless -f Loadbars::Constants->CONFFILE;

    display_info "Reading configuration from " . Loadbars::Constants->CONFFILE;
    open my $conffile, Loadbars::Constants->CONFFILE or die "$!: " . Loadbars::Constants->CONFFILE . "\n";

    while (<$conffile>) {
        chomp;
        s/[\t\s]*?#.*//;

        next unless length;

        my ($key, $val) = split '=';

        unless (defined $val) {
            display_warn "Could not parse config line: $_";
            next;
        }

        trim $key; trim $val;

        if (not exists $C{$key}) {
            display_warn "There is no such config key: $key, ignoring";

        } else {
            display_info "Setting $key=$val, it might be overwritten by command line params.";
            $C{$key} = $val;
        }
    }

    close $conffile;
}

sub write_config () {
    display_warn "Overwriting config file " . Loadbars::Constants->CONFFILE if -f Loadbars::Constants->CONFFILE;

    open my $conffile, '>', Loadbars::Constants->CONFFILE or do {
        display_warn "$!: " . Loadbars::Constants->CONFFILE;

        return undef;
    };

    for (keys %C) {
        print $conffile "$_=$C{$_}\n";
    }

    close $conffile;
}

sub terminate_pids (@) {
    my @threads = @_;

    display_info 'Terminating sub-processes, hasta la vista!';
    $_->kill('TERM') for @threads;
    display_info_no_nl 'Terminating PIDs';
    for my $pid (keys %PIDS) {
        my $proc_table = Proc::ProcessTable->new();
        for my $proc (@{$proc_table->table()}) {
            if ($proc->ppid == $pid) {
                print $proc->pid . ' ';
                kill 'TERM', $proc->pid if $proc->ppid == $pid;
            }
        }
        
        print $pid . ' ';
        kill 'TERM', $pid;
    }

    say '';

    display_info 'Terminating done. I\'ll be back!';
}

sub stats_thread ($;$) {
    my ( $host, $user ) = @_;
    $user = defined $user ? "-l $user" : '';

    my ($sigusr1, $sigterm) = (0,0);
    my $loadavgexp = qr/(\d+\.\d{2}) (\d+\.\d{2}) (\d+\.\d{2})/;
    my $inter = Loadbars::Constants->INTERVAL;

    until ($sigterm) {
        my $bash = <<"BASH";
            loadavg=/proc/loadavg
            stat=/proc/stat
            meminfo=/proc/meminfo
            
            for i in \$(seq $C{samples}); do 
                echo CPUSTATS
                cat \$loadavg \$stat 
                echo MEMSTATS
                cat \$meminfo 
                sleep $inter
            done
BASH

        my $cmd =
            ($host eq 'localhost' || $host eq '127.0.0.1')
          ? $bash
          : "ssh $user -o StrictHostKeyChecking=no $C{sshopts} $host '$bash'";

        my $pid = open my $pipe, "$cmd |" or do {
            say "Warning: $!";
            sleep 0.5;
            next;
        };

        $PIDS{$pid} = 1;

        # Toggle CPUs
        $SIG{USR1} = sub { $sigusr1 = 1 };
        $SIG{TERM} = sub { $sigterm = 1 };

        my $cpuregexp = qr/$I{cpuregexp}/;
        # 1=cpu, 2=mem, 3=net
        my $mode = 0;

    while (<$pipe>) {
            chomp;

            if ($mode == 0) {
                if ($_ eq 'MEMSTATS') {
                    $mode = 1;

                } elsif (/^$loadavgexp/) {
                    $AVGSTATS{$host} = "$1;$2;$3";
    
                } elsif (/$cpuregexp/) {
                   my ( $name, $load ) = parse_cpu_line $_;
                   $CPUSTATS{"$host;$name"} = join ';',
                     map  { $_ . '=' . $load->{$_} }
                     grep { defined $load->{$_} } keys %$load;
               }
            } elsif ($mode == 1) {
                if ($_ eq 'CPUSTATS') {
                    $mode = 0;

                } else {
                    for my $meminfo (qw(MemTotal MemFree Buffers Cached SwapTotal SwapFree)) {
                        # TODO: Precompile regexp
                        if (/^$meminfo: *(\d+)/) {
                            $MEMSTATS_HAS{$host} = 1;
                            $MEMSTATS{"$host;$meminfo"} = $1;
                        }
                    }
                }
            }

            if ($sigusr1) {
                # TODO: Use index instead of regexp for cpuregexp
                $cpuregexp = qr/$I{cpuregexp}/;
                $sigusr1   = 0;

            } elsif ($sigterm) {
                close $pipe;
                last;
            }
        }

        delete $PIDS{$pid};
    }

    return undef;
}

sub get_rect ($$) {
    my ( $rects, $name ) = @_;

    return $rects->{$name} if exists $rects->{$name};
    return $rects->{$name} = SDL::Rect->new();
}

sub normalize_loads (%) {
    my %loads = @_;

    return %loads unless exists $loads{TOTAL};

    my $total = $loads{TOTAL} == 0 ? 1 : $loads{TOTAL};
    return map { $_ => $loads{$_} / ($total / 100)  } keys %loads;
}

sub get_cpuaverage ($@) {
    my ($factor, @loads) = @_;
    my (%cpumax, %cpuaverage);

    for my $l (@loads) {
        for (keys %$l) {
            $cpuaverage{$_} += $l->{$_};

            $cpumax{$_} = $l->{$_}
              if not exists $cpumax{$_}
                  or $cpumax{$_} < $l->{$_};
        }
    }

    my $div = @loads / $factor;

    for (keys %cpuaverage) {
        $cpuaverage{$_} /= $div;
        $cpumax{$_} /= $factor;
    }

    return (\%cpumax, \%cpuaverage);
}

sub draw_background ($$) {
    my ($app, $rects) = @_;
    my $rect = get_rect $rects, 'background';

    $rect->width($C{width});
    $rect->height($C{height});
    $app->fill($rect, Loadbars::Constants->BLACK);
    $app->update($rect);

    return undef;
}

sub create_threads (@) {
    return 
        map { $_->detach(); $_ } 
        map { threads->create( 'stats_thread', split ':' ) } @_;
}

sub auto_off_text ($) {
    my ($barwidth) = @_;

    if ($barwidth < $C{barwidth} - 1 && $I{showtextoff} == 0) {
        return unless $C{showtext};
        display_warn 'Disabling text display, text does not fit into window. Use \'t\' to re-enable.';
        $I{showtextoff} = 1;
        $C{showtext} = 0;

    } elsif ($I{showtextoff} == 1 && $barwidth >= $C{barwidth} - 1) {
        display_info 'Re-enabling text display, text fits into window now.';
        $C{showtext} = 1;
        $I{showtextoff} = 0;
    }

    return undef;
}

sub set_dimensions ($$) {
    my ($width, $height) = @_;
    my $display_info = 0;

    if ($width < 1) {
        $C{width} = 1 if $C{width} != 1;

    } elsif ($width > $C{maxwidth}) {
        $C{width} = $C{maxwidth} if $C{width} != $C{maxwidth};

    } elsif ($C{width} != $width) {
        $C{width} = $width;
    }

    if ($height < 1) {
        $C{height} = 1 if $C{height} != 1;

    } elsif ($C{height} != $height) {
        $C{height} = $height;
    }
}

sub main_loop ($@) {
    my ( $dispatch, @threads ) = @_;

    my $num_stats = 1;
    $C{width} = $C{barwidth};

    my $app = SDL::App->new(
        -title      => Loadbars::Constants->VERSION . ' (press h for help on stdout)',
        -icon_title => Loadbars::Constants->VERSION,
        -width      => $C{width},
        -height     => $C{height},
        -depth      => Loadbars::Constants->COLOR_DEPTH,
        -resizeable => 1,
    );

    SDL::Font->new('font.png')->use();

    my $rects = {};
    my %prev_stats;
    my %last_loads;

    my $redraw_background = 0;
    my $font_height       = 14;

    my $infotxt : shared = '';
    my $quit : shared = 0;
    my $resize_window : shared = 0;
    my %newsize : shared;
    my $event = SDL::Event->new();

    my ( $t1, $t2 ) = ( Time::HiRes::time(), undef );

    # Closure for event handling
    my $event_handler = sub {
        # While there are events to poll, poll them all!
        while ($event->poll() == 1) {
            next if $event->type() != 2;
            my $key_name = $event->key_name();
            
            if ( $key_name eq '1' ) {
                $C{showcores} = !$C{showcores};
                set_showcores_regexp;
                $_->kill('USR1') for @threads;
                %AVGSTATS    = ();
                %CPUSTATS    = ();
                $redraw_background = 1;
                display_info 'Toggled CPUs';
            
            } elsif ( $key_name eq 'e' ) {
                $C{extended} = !$C{extended};
                $redraw_background = 1;
                display_info 'Toggled extended display';
            
            } elsif ( $key_name eq 'h' ) {
                say '=> Hotkeys to use in the SDL interface';
                say $dispatch->('hotkeys');
                display_info 'Hotkeys help printed on terminal stdout';
            
            } elsif ( $key_name eq 'm' ) {
                $C{showmem} = !$C{showmem};
                display_info 'Toggled show mem';
            
            } elsif ( $key_name eq 't' ) {
                $C{showtext} = !$C{showtext};
                $redraw_background = 1;
                display_info 'Toggled text display';
            
            } elsif ( $key_name eq 'u' ) {
                $C{showtexthost} = !$C{showtexthost};
                $redraw_background = 1;
                display_info 'Toggled number/hostname display';
            
            } elsif ( $key_name eq 'q' ) {
                terminate_pids @threads;
                $quit = 1;
                return;
            
            } elsif ( $key_name eq 'w' ) {
                    write_config;
                
                } elsif ( $key_name eq 'a' ) {
                    ++$C{average};
                    display_info "Set sample average to $C{average}";
                } elsif ( $key_name eq 'y' or $key_name eq 'z' ) {
                    my $avg = $C{average};
                    --$avg;
                    $C{average} = $avg > 1 ? $avg : 2;
                    display_info "Set sample average to $C{average}";
                
                } elsif ( $key_name eq 's' ) {
                    $C{factor} += 0.1;
                    display_info "Set scale factor to $C{factor}";
                } elsif ( $key_name eq 'x' or $key_name eq 'z' ) {
                    $C{factor} -= 0.1;
                    display_info "Set scale factor to $C{factor}";
                
                } elsif ( $key_name eq 'left') {
                    $newsize{width} = $C{width} - 100;
                    $newsize{height} = $C{height};
                    $resize_window = 1;
                } elsif ( $key_name eq 'right' ) {
                    $newsize{width} = $C{width} + 100;
                    $newsize{height} = $C{height};
                    $resize_window = 1;

                } elsif ( $key_name eq 'up' ) {
                    $newsize{width} = $C{width};
                    $newsize{height} = $C{height} - 100;
                    $resize_window = 1;
                } elsif ( $key_name eq 'down' ) {
                    $newsize{width} = $C{width};
                    $newsize{height} = $C{height} + 100;
                    $resize_window = 1;
                }
            }
        };

        do {
            my ( $x, $y ) = ( 0, 0 );

            # Also substract 1 (each bar is followed by an 1px separator bar)
            my $width = $C{width} / notnull($num_stats) - 1;

            my ( $current_barnum, $current_corenum ) = ( -1, -1 );

            for my $key ( sort keys %CPUSTATS ) {
                last if (++$current_barnum > $num_stats);
                ++$current_corenum;
                my ( $host, $name ) = split ';', $key;

                next unless defined $CPUSTATS{$key};

                my %stat = map {
                    my ( $k, $v ) = split '=';
                    $k => $v

                } split ';', $CPUSTATS{$key};

                unless ( exists $prev_stats{$key} ) {
                    $prev_stats{$key} = \%stat;
                    next;
                }

                my $prev_stat = $prev_stats{$key};
                my %loads =
                  null $stat{TOTAL} == null $prev_stat->{TOTAL}
                  ? %stat
                  : map { $_ => $stat{$_} - $prev_stat->{$_} } keys %stat;

                $prev_stats{$key} = \%stat;

                %loads = normalize_loads %loads;
                push @{ $last_loads{$key} }, \%loads;
                shift @{ $last_loads{$key} }
                  while @{ $last_loads{$key} } >= $C{average};

                my ( $cpumax, $cpuaverage ) = get_cpuaverage $C{factor},
                  @{ $last_loads{$key} };

                my %heights = map {
                        $_ => defined $cpuaverage->{$_}
                      ? $cpuaverage->{$_} * ( $C{height} / 100 )
                      : 1
                } keys %$cpuaverage;

                my $is_host_summary = $name eq 'cpu' ? 1 : 0;

                my $rect_separator = undef;

                my $rect_idle = get_rect $rects, "$key;idle";
                my $rect_steal = get_rect $rects, "$key;steal";
                my $rect_guest = get_rect $rects, "$key;guest";
                my $rect_irq = get_rect $rects, "$key;irq";
                my $rect_softirq = get_rect $rects, "$key;softirq";
                my $rect_nice = get_rect $rects, "$key;nice";
                my $rect_iowait = get_rect $rects, "$key;iowait";
                my $rect_user = get_rect $rects, "$key;user";
                my $rect_system = get_rect $rects, "$key;system";

                my $rect_peak;

                $y = $C{height} - $heights{system};
                $rect_system->width($width);
                $rect_system->height( $heights{system} );
                $rect_system->x($x);
                $rect_system->y($y);

                $y -= $heights{user};
                $rect_user->width($width);
                $rect_user->height( $heights{user} );
                $rect_user->x($x);
                $rect_user->y($y);

                $y -= $heights{nice};
                $rect_nice->width($width);
                $rect_nice->height( $heights{nice} );
                $rect_nice->x($x);
                $rect_nice->y($y);

                $y -= $heights{idle};
                $rect_idle->width($width);
                $rect_idle->height( $heights{idle} );
                $rect_idle->x($x);
                $rect_idle->y($y);

                $y -= $heights{iowait};
                $rect_iowait->width($width);
                $rect_iowait->height( $heights{iowait} );
                $rect_iowait->x($x);
                $rect_iowait->y($y);

                $y -= $heights{irq};
                $rect_irq->width($width);
                $rect_irq->height( $heights{irq} );
                $rect_irq->x($x);
                $rect_irq->y($y);

                $y -= $heights{softirq};
                $rect_softirq->width($width);
                $rect_softirq->height( $heights{softirq} );
                $rect_softirq->x($x);
                $rect_softirq->y($y);

                $y -= $heights{guest};
                $rect_guest->width($width);
                $rect_guest->height( $heights{guest} );
                $rect_guest->x($x);
                $rect_guest->y($y);

                $y -= $heights{steal};
                $rect_steal->width($width);
                $rect_steal->height( $heights{steal} );
                $rect_steal->x($x);
                $rect_steal->y($y);

                my $all     = 100 - $cpuaverage->{idle};
                my $max_all = 0;

                $app->fill( $rect_idle,    Loadbars::Constants->BLACK );
                $app->fill( $rect_steal,   Loadbars::Constants->RED );
                $app->fill( $rect_guest,   Loadbars::Constants->RED );
                $app->fill( $rect_irq,     Loadbars::Constants->WHITE );
                $app->fill( $rect_softirq, Loadbars::Constants->WHITE );
                $app->fill( $rect_nice,    Loadbars::Constants->GREEN );
                $app->fill( $rect_iowait,  Loadbars::Constants->PURPLE );

                my $add_x = 0;
                my $rect_memused = get_rect $rects, "$host;memused";
                my $rect_memfree = get_rect $rects, "$host;memfree";
                my $rect_buffers = get_rect $rects, "$host;buffers";
                my $rect_cached = get_rect $rects, "$host;cached";
                my $rect_swapused = get_rect $rects, "$host;swapused";
                my $rect_swapfree = get_rect $rects, "$host;swapfree";

                my %meminfo;
                if ( $is_host_summary ) {
                    if ( $C{showmem} ) {
                        $add_x = $width + 1;

                        my $ram_per = percentage $MEMSTATS{"$host;MemTotal"}, $MEMSTATS{"$host;MemFree"};
                        my $swap_per = percentage $MEMSTATS{"$host;SwapTotal"}, $MEMSTATS{"$host;SwapFree"};

                        %meminfo = (
                            ram_per => $ram_per,
                            swap_per => $swap_per,
                        );

                        my %heights = (
                                MemFree => $ram_per * ( $C{height} / 100 ),
                                MemUsed => (100 - $ram_per) * ( $C{height} / 100 ),
                                SwapFree => $swap_per * ( $C{height} / 100 ),
                                SwapUsed => (100 - $swap_per) * ( $C{height} / 100 ),
                        );

                        my $half_width = $width / 2;
                        $y = $C{height} - $heights{MemUsed};
                        $rect_memused->width($half_width);
                        $rect_memused->height( $heights{MemUsed} );
                        $rect_memused->x($x+$add_x);
                        $rect_memused->y($y);

                        $y -= $heights{MemFree};
                        $rect_memfree->width($half_width);
                        $rect_memfree->height( $heights{MemFree} );
                        $rect_memfree->x($x+$add_x);
                        $rect_memfree->y($y);

                        $y = $C{height} - $heights{SwapUsed};
                        $rect_swapused->width($half_width);
                        $rect_swapused->height( $heights{SwapUsed} );
                        $rect_swapused->x($x+$add_x+$half_width);
                        $rect_swapused->y($y);

                        $y -= $heights{SwapFree};
                        $rect_swapfree->width($half_width);
                        $rect_swapfree->height( $heights{SwapFree} );
                        $rect_swapfree->x($x+$add_x+$half_width);
                        $rect_swapfree->y($y);
                        
                        $app->fill( $rect_memused,   Loadbars::Constants->DARK_GREY );
                        $app->fill( $rect_memfree,    Loadbars::Constants->BLACK );

                        $app->fill( $rect_swapused,   Loadbars::Constants->GREY );
                        $app->fill( $rect_swapfree,    Loadbars::Constants->BLACK );
                    }

                    if ( $C{showcores} ) {
                        $current_corenum = 0;
                        $rect_separator = get_rect $rects, "$key;separator";
                        $rect_separator->width(1);
                        $rect_separator->height( $C{height} );
                        $rect_separator->x( $x - 1 );
                        $rect_separator->y(0);
                        $app->fill( $rect_separator, Loadbars::Constants->GREY );
                    }
                }

                if ( $C{extended} ) {
                    my %maxheights = map {
                            $_ => defined $cpumax->{$_}
                          ? $cpumax->{$_} * ( $C{height} / 100 )
                          : 1
                    } keys %$cpumax;

                    $rect_peak = get_rect $rects, "$key;max";
                    $rect_peak->width($width);
                    $rect_peak->height(1);
                    $rect_peak->x($x);
                    $rect_peak->y( $C{height} - $maxheights{system} - $maxheights{user} );

                    $max_all = sum @{$cpumax} {qw(user system iowait irq softirq steal guest)};

                    $app->fill( $rect_peak, $max_all > Loadbars::Constants->USER_ORANGE ? Loadbars::Constants->ORANGE
                        : ( $max_all > Loadbars::Constants->USER_YELLOW0 ? Loadbars::Constants->YELLOW0 : (Loadbars::Constants->YELLOW)));
                }

                $app->fill( $rect_user, $all > Loadbars::Constants->USER_ORANGE ? Loadbars::Constants->ORANGE
                    : ( $all > Loadbars::Constants->USER_YELLOW0 ? Loadbars::Constants->YELLOW0 : (Loadbars::Constants->YELLOW)));
                $app->fill( $rect_system, $cpuaverage->{system} > Loadbars::Constants->SYSTEM_BLUE0
                    ? Loadbars::Constants->BLUE0 : Loadbars::Constants->BLUE );

                my ( $y, $space ) = ( 5, $font_height );

                my @loadavg = split ';', $AVGSTATS{$host};

                if ( $C{showtext} ) {
                    if ( $C{showmem} && $is_host_summary ) {
                        my $y_ = $y;
                        $app->print( $x+$add_x, $y_, 'Ram:');
                        $app->print( $x+$add_x, $y_ += $space, sprintf '%02d', (100-$meminfo{ram_per}));
                        $app->print( $x+$add_x, $y_ += $space, 'Swp:');
                        $app->print( $x+$add_x, $y_ += $space, sprintf '%02d', (100-$meminfo{swap_per}));
                    }
                    if ( $C{showtexthost} && $is_host_summary ) {
                        # If hostname is printed don't use FQDN
                        # because of its length.
                        $host =~ /([^\.]*)/;
                        $app->print( $x, $y, sprintf '%s:', $1 );

                    }
                    else {
                        $app->print( $x, $y, sprintf '%i:', $C{showcores} ? $current_corenum : $current_barnum + 1 );
                    }

                    if ( $C{extended} ) {
                        $app->print( $x, $y += $space, sprintf '%02d%s', norm $cpuaverage->{steal}, 'st');
                        $app->print( $x, $y += $space, sprintf '%02d%s', norm $cpuaverage->{guest}, 'gt');
                        $app->print( $x, $y += $space, sprintf '%02d%s', norm $cpuaverage->{softirq}, 'sr');
                        $app->print( $x, $y += $space, sprintf '%02d%s', norm $cpuaverage->{irq}, 'ir');
                    }

                    $app->print( $x, $y += $space, sprintf '%02d%s', norm $cpuaverage->{iowait}, 'io');

                    $app->print( $x, $y += $space, sprintf '%02d%s', norm $cpuaverage->{idle}, 'id') if $C{extended};

                    $app->print( $x, $y += $space, sprintf '%02d%s', norm $cpuaverage->{nice}, 'ni');
                    $app->print( $x, $y += $space, sprintf '%02d%s', norm $cpuaverage->{user}, 'us');
                    $app->print( $x, $y += $space, sprintf '%02d%s', norm $cpuaverage->{system}, 'sy');
                    $app->print( $x, $y += $space, sprintf '%02d%s', norm $all, 'to');

                    $app->print( $x, $y += $space, sprintf '%02d%s', norm $max_all, 'pk') if $C{extended};

                    if ($is_host_summary) {
                    if ( defined $loadavg[0] ) {
                        $app->print( $x, $y += $space, 'Avg:' );
                        $app->print( $x, $y += $space, sprintf "%.2f", $loadavg[0]);
                        $app->print( $x, $y += $space, sprintf "%.2f", $loadavg[1]);
                        $app->print( $x, $y += $space, sprintf "%.2f", $loadavg[2]);
                    }
                }
            }

            $app->update(
                $rect_idle,  $rect_iowait,  $rect_irq,
                $rect_nice,  $rect_softirq, $rect_steal,
                $rect_guest, $rect_system,  $rect_user,
            );

            $app->update( $rect_memfree, $rect_memused, $rect_swapused, $rect_swapfree ) if $C{showmem};
            $app->update($rect_separator) if defined $rect_separator;

            $x += $width + 1 + $add_x;

        }

      TIMEKEEPER:
        $t2 = Time::HiRes::time();
        my $t_diff = $t2 - $t1;

        if ( Loadbars::Constants->INTERVAL > $t_diff ) {
            usleep 10000;

            # Goto is OK as long you don't produce spaghetti code
            goto TIMEKEEPER;

        } elsif ( Loadbars::Constants->INTERVAL_WARN < $t_diff ) {
            display_warn  "WARN: Loop is behind $t_diff seconds, your computer may be too slow";
        }

        $t1 = $t2;
        $event_handler->();

        my $new_num_stats = keys %CPUSTATS;
        $new_num_stats += keys %MEMSTATS_HAS if $C{showmem};

        if ( $new_num_stats != $num_stats ) {
            %prev_stats = ();
            %last_loads = ();

            $num_stats = $new_num_stats;
            $newsize{width} = $C{barwidth} * $num_stats;
            $newsize{height} = $C{height};
            $resize_window = 1;
        }

        if ($resize_window) {
            set_dimensions $newsize{width}, $newsize{height};
            $app->resize( $C{width}, $C{height} );
            $resize_window = 0;
            $redraw_background = 1;
        } 

        if ($redraw_background) {
            draw_background $app, $rects;
            $redraw_background = 0;
        }

        auto_off_text $width;

    } until $quit;

    say "Good bye";

    exit Loadbars::Constants->SUCCESS;
}

sub dispatch_table () {
    my $hosts = '';

    my $textdesc = <<END;
CPU stuff:
    st = Steal in % [see man proc] (extended)
        Color: Red
    gt = Guest in % [see man proc] (extended)
        Color: Red
    sr = Soft IRQ usage in % (extended)
        Color: White
    ir = IRQ usage in % (extended)
        Color: White
    io = IOwait cpu sage in % 
        Color: Purple
    id = Idle cpu usage in % (extended)
        Color: Black
    ni = Nice cpu usage in % 
        Color: Green
    us = User cpu usage in % 
        Color: Yellow, dark yellow if to>50%, orange if to>50%
    sy = System cpu sage in % 
        Blue, lighter blue if >30%
    to = Total CPU usage, which is (100% - id)
    pk = Max us+sy peak of last avg. samples (extended)
    avg = System load average; desc. order: 1, 5 and 15 min. avg. 
    1px horizontal line: Maximum sy+us+io of last 'avg' samples (extended)
    Extended means: text display only if extended mode is turned on
Memory stuff:
    Ram: System ram usage in %
        Color: Dark grey
    Swp: System swap usage in %
        Color: Grey
Config file support:
    Loadbars tries to read ~/.loadbarsrc and it's possible to configure any
    option you find in --help but without leading '--'. For comments just use
    the '#' sign. Sample config:
        showcores=1 # Always show cores on startup
        showtext=0 # Always don't display text on startup
        extended=1 # Always use extended mode on startup
    will always show all CPU cores in extended mode but no text display. 
Examples:
    loadbars --extended 1 --showcores 1 --height 300 --hosts localhost
    loadbars --hosts localhost,server1.example.com,server2.example.com
    loadbars --cluster foocluster (foocluster is in /etc/clusters [ClusterSSH])
END

    # mode 1: Option is shown in the online help menu (stdout not sdl)
    # mode 2: Option is shown in the 'usage' screen from the command line
    # mode 4: Option is used to generate the GetOptions parameters for Getopt::Long
    # Combinations: Like chmod(1)

    my %d = (
        average => {
            menupos => 3,
            help    => 'Num of samples for avg. (more fluent animations)',
            mode    => 6,
            type    => 'i'
        },
        average_hot_up => {
            menupos => 4,
            cmd     => 'a',
            help    => 'Increases number of samples for calculating avg. by 1',
            mode    => 1
        },
        average_hot_dn => {
            menupos => 5,
            cmd     => 'y',
            help    => 'Decreases number of samples for calculating avg. by 1',
            mode    => 1
        },

        barwidth => {
            menupos => 5,
            help    => 'Set bar width',
            mode    => 6,
            type    => 'i'
        },
        windowwidth_hot_up => {
            menupos => 90,
            help    => 'Increase window width by 100px',
            cmd     => 'right',
            mode    => 1,
        },
        windowwidth_hot_dn => {
            menupos => 91,
            help    => 'Decrease window width by 100px',
            cmd     => 'left',
            mode    => 1,
        },
        windowheight_hot_up => {
            menupos => 92,
            help    => 'Increase window height by 100px',
            cmd     => 'down',
            mode    => 1,
        },
        windowheight_hot_dn => {
            menupos => 93,
            help    => 'Decrease window height by 100px',
            cmd     => 'up',
            mode    => 1,
        },

        cluster => {
            menupos => 6,
            help    => 'Cluster name from /etc/clusters',
            var     => \$C{cluster},
            mode    => 6,
            type    => 's'
        },
        configuration => {
            menupos => 6,
            cmd     => 'c',
            help    => 'Show current configuration',
            mode    => 4
        },

        extended => {
            menupos => 6,
            help    => 'Toggle extended display (0 or 1)',
            mode    => 7,
            type    => 'i'
        },
        extended_hot => {
            menupos => 23,
            cmd     => 'e',
            help    => 'Toggle extended mode',
            mode    => 1
        },

        factor => {
            menupos => 7,
            help    => 'Set graph scale factor (1.0 means 100%)',
            mode    => 6,
            type    => 's'
        },
        factor_hot_up => {
            menupos => 8,
            cmd     => 's',
            help    => 'Increases graph scale factor by 0.1',
            mode    => 1
        },
        factor_hot_dn => {
            menupos => 9,
            cmd     => 'x',
            help    => 'Decreases graph scale factor by 0.1',
            mode    => 1
        },

        height => {
            menupos => 10,
            help    => 'Set windows height',
            mode    => 6,
            type    => 'i'
        },

        help_hot => {
            menupos => 11,
            cmd     => 'h',
            help    => 'Prints this help screen',
            mode    => 1
        },

        hosts => {
            menupos => 12,
            help =>
              'Comma sep. list of hosts; optional: user@ in front to each host',
            var  => \$hosts,
            mode => 6,
            type => 's'
        },

        maxwidth => {
            menupos => 16,
            help    => 'Set max width',
            mode    => 6,
            type    => 'i'
        },

        quit_hot => { menupos => 16, cmd => 'q', help => 'Quits', mode => 1 },
        writeconfig_hot => { menupos => 16, cmd => 'w', help => 'Write config to config file', mode => 1 },

        samples => {
            menupos => 17,
            help    => 'Set number of samples until ssh reconnects',
            mode    => 6,
            type    => 'i'
        },

        showcores => {
            menupos => 17,
            help    => 'Toggle core display (0 or 1)',
            mode    => 7,
            type    => 'i'
        },
        showcores_hot =>
          { menupos => 17, cmd => '1', help => 'Toggle show cores', mode => 1 },

        showmem => {
            menupos => 17,
            help    => 'Toggle mem display (0 or 1)',
            mode    => 7,
            type    => 'i'
        },
        showmem_hot =>
          { menupos => 17, cmd => 'm', help => 'Toggle show mem', mode => 1 },

        showtexthost => {
            menupos => 18,
            help    => 'Toggle hostname/num text display (0 or 1)',
            mode    => 7,
            type    => 'i'
        },
        showtexthost_hot => {
            menupos => 18,
            cmd     => 'u',
            help    => 'Toggle hostname/num text display',
            mode    => 1
        },

        showtext => {
            menupos => 19,
            help    => 'Toggle text display (0 or 1)',
            mode    => 7,
            type    => 'i'
        },
        showtext_hot => {
            menupos => 19,
            cmd     => 't',
            help    => 'Toggle text display',
            mode    => 1
        },

        sshopts =>
          { menupos => 20, help => 'Set SSH options', mode => 6, type => 's' },
    );

    my %d_by_short = map {
        $d{$_}{cmd} => $d{$_}

      } grep {
        exists $d{$_}{cmd}

      } keys %d;

    my $closure = sub ($;$) {
        my ( $arg, @rest ) = @_;

        if ( $arg eq 'command' ) {
            my ( $cmd, @args ) = @rest;

            my $cb = $d{$cmd};
            $cb = $d_by_short{$cmd} unless defined $cb;

            unless ( defined $cb ) {
                system $cmd;
                return 0;
            }

            if ( length $cmd == 1 ) {
                for my $key ( grep { exists $d{$_}{cmd} } keys %d ) {
                    do { $cmd = $key; last } if $d{$key}{cmd} eq $cmd;
                }
            }

        }
        elsif ( $arg eq 'hotkeys' ) {
            $textdesc . "Hotkeys:\n" . (
                join "\n",
                map {
                    "$_\t- $d_by_short{$_}{help}"

                  } grep {
                    $d_by_short{$_}{mode} & 1 and exists $d_by_short{$_}{help};

                  } sort { $d_by_short{$a}{menupos} <=> $d_by_short{$b}{menupos} }
                  sort keys %d_by_short
            );

        }
        elsif ( $arg eq 'usage' ) {
            $textdesc . (
                join "\n",
                map {
                    if ( $_ eq 'help' )
                    {
                        "--$_\t\t- $d{$_}{help}";
                    }
                    else {
                        "--$_ <ARG>\t- $d{$_}{help}";
                    }

                  } grep {
                    $d{$_}{mode} & 2
                      and exists $d{$_}{help}

                  } sort { $d{$a}{menupos} <=> $d{$b}{menupos} } sort keys %d
            );

        }
        elsif ( $arg eq 'options' ) {
            map {
                "$_="
                  . $d{$_}{type} =>
                  ( defined $d{$_}{var} ? $d{$_}{var} : \$C{$_} );

              } grep {
                $d{$_}{mode} & 4 and exists $d{$_}{type};

              } sort keys %d;
        }
    };

    $d{configuration}{cb} = sub {
        say sort map {
            "$_->[0] = $_->[1]"

          } grep {
            defined $_->[1]

          } map {
            [ $_ => exists $d{$_}{var} ? ${ $d{$_}{var} } : $C{$_} ]

          } keys %d;
    };

    return ( \$hosts, $closure );
}

# Recursuve function
sub get_cluster_hosts ($;$);

sub get_cluster_hosts ($;$) {
    my ( $cluster, $recursion ) = @_;

    unless ( defined $recursion ) {
        $recursion = 1;

    }
        elsif ( $recursion > Loadbars::Constants->CSSH_MAX_RECURSION ) {
        error "CSSH_MAX_RECURSION reached. Infinite circle loop in "
          . Loadbars::Constants->CSSH_CONFFILE . "?";
    }

    open my $fh, Loadbars::Constants->CSSH_CONFFILE or error "$!: " . Loadbars::Constants->CSSH_CONFFILE;
    my $hosts;

    while (<$fh>) {
        if (/^$cluster\s*(.*)/) {
            $hosts = $1;
            last;
        }
    }

    close $fh;

    unless ( defined $hosts ) {
        error "No such cluster in " . Loadbars::Constants->CSSH_CONFFILE . ": $cluster"
          unless defined $recursion;

        return ($cluster);
    }

    my @hosts;
    push @hosts, get_cluster_hosts $_, ( $recursion + 1 )
      for ( split /\s+/, $hosts );

    return @hosts;
}

1;
