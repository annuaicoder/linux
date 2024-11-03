#!/usr/bin/perl
use strict;
use warnings;
use File::Copy;
use File::Path qw(make_path remove_tree);
use Getopt::Long;
use Config::Simple;
use Log::Log4perl qw(get_logger :levels);
use File::Find;
use threads;
use Thread::Queue;
use File::Basename;
use File::Spec;
use Digest::MD5 qw(md5_hex);
use Term::ReadKey;

# Initialize Logger
my $log_conf = q(
    log4perl.rootLogger              = DEBUG, LOGFILE, Screen

    log4perl.appender.LOGFILE        = Log::Log4perl::Appender::File
    log4perl.appender.LOGFILE.filename = directory_organizer.log
    log4perl.appender.LOGFILE.mode   = append
    log4perl.appender.LOGFILE.layout = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.LOGFILE.layout.ConversionPattern = [%d] %p %m%n

    log4perl.appender.Screen         = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr  = 0
    log4perl.appender.Screen.layout  = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Screen.layout.ConversionPattern = [%d] %p %m%n
);
Log::Log4perl::init( \$log_conf );
my $logger = get_logger();

# Configuration Defaults
my $config_file = 'organizer.conf';
my %config = (
    root_dir         => 'Documentation',
    backup_dir       => 'Backup',
    log_level        => 'DEBUG',
    threads          => 4,
    interactive      => 0,
    config_file      => $config_file,
    include_hidden   => 0,
    dry_run          => 0,
    exclude_patterns => '',
);

# Define Organizational Structure
my %dir_structure = (
    'Documents'      => qr/\.(txt|doc|docx|pdf|odt|rtf)$/i,
    'Images'         => qr/\.(jpg|jpeg|png|gif|bmp|tiff|svg)$/i,
    'Videos'         => qr/\.(mp4|avi|mkv|mov|wmv|flv)$/i,
    'Music_Sounds'   => qr/\.(mp3|wav|flac|aac|ogg|m4a)$/i,
    'Archives'       => qr/\.(zip|tar|gz|rar|7z|bz2)$/i,
    'Scripts'        => qr/\.(sh|pl|py|rb|js|php|bat|ps1)$/i,
    'Executables'    => qr/\.(exe|msi|bin|deb|rpm)$/i,
    'Fonts'          => qr/\.(ttf|otf|woff|woff2)$/i,
    'Ebooks'         => qr/\.(epub|mobi|azw3)$/i,
    'Presentations'  => qr/\.(ppt|pptx|odp)$/i,
    'Spreadsheets'   => qr/\.(xls|xlsx|ods|csv)$/i,
    'Others'         => qr/./, # Catch-all for uncategorized files
);

# Command-Line Options
GetOptions(
    'config=s'      => \$config{config_file},
    'root=s'        => \$config{root_dir},
    'backup=s'      => \$config{backup_dir},
    'threads=i'     => \$config{threads},
    'interactive!'  => \$config{interactive},
    'dry-run!'      => \$config{dry_run},
    'include-hidden!' => \$config{include_hidden},
    'exclude=s'     => \$config{exclude_patterns},
) or die "Error in command line arguments\n";

# Load Configuration File if exists
if (-e $config{config_file}) {
    Config::Simple->import_from($config{config_file}, \%config) or die Config::Simple->error();
    $logger->info("Loaded configuration from $config{config_file}");
}

# Override config with command-line arguments
# Already handled by GetOptions

# Set Log Level
Log::Log4perl::init( \$log_conf );
$logger->level($config{log_level});

# Create Backup Directory
unless (-d $config{backup_dir}) {
    make_path($config{backup_dir}) or $logger->fatal("Failed to create backup directory: $!");
    $logger->info("Created backup directory: $config{backup_dir}");
}

# Create Organizational Directories
foreach my $dir (keys %dir_structure) {
    my $path = File::Spec->catdir($config{root_dir}, $dir);
    unless (-d $path) {
        make_path($path) or $logger->fatal("Failed to create directory $path: $!");
        $logger->info("Created directory: $path");
    }
}

# Initialize Queue for Multi-threading
my $file_queue = Thread::Queue->new();

# Worker Threads
sub worker {
    while (defined (my $file = $file_queue->dequeue())) {
        process_file($file);
    }
}

# Start Worker Threads
my @threads;
for (1..$config{threads}) {
    push @threads, threads->create(\&worker);
}

# Enqueue Files
find(\&wanted, $config{root_dir});

# Signal threads to finish
$file_queue->end();

# Wait for all threads to finish
$_->join() for @threads;

print "Directory organization complete.\n";
$logger->info("Directory organization complete.");

# Subroutine to process each file
sub process_file {
    my ($file_path) = @_;

    # Skip directories
    return if -d $file_path;

    # Skip hidden files if not included
    if (!$config{include_hidden} && basename($file_path) =~ /^\./) {
        $logger->debug("Skipping hidden file: $file_path");
        return;
    }

    # Skip excluded patterns
    if ($config{exclude_patterns} && $file_path =~ /$config{exclude_patterns}/) {
        $logger->debug("Skipping excluded file: $file_path");
        return;
    }

    my ($filename, $directories, $suffix) = fileparse($file_path, qr/\.[^.]*/);

    # Determine category
    my $category = 'Others';
    foreach my $cat (keys %dir_structure) {
        if ($filename =~ $dir_structure{$cat}) {
            $category = $cat;
            last;
        }
    }

    my $dest_dir = File::Spec->catdir($config{root_dir}, $category);
    my $dest_path = File::Spec->catfile($dest_dir, $filename . $suffix);

    # Check for name conflicts
    if (-e $dest_path) {
        my $unique_suffix = "_" . md5_hex(time . rand());
        $dest_path = File::Spec->catfile($dest_dir, $filename . $unique_suffix . $suffix);
        $logger->warn("Name conflict for $filename. Renaming to " . $filename . $unique_suffix . $suffix);
    }

    # Interactive confirmation
    if ($config{interactive}) {
        print "Move $file_path to $dest_path? (y/n): ";
        ReadMode('cbreak');
        my $response = ReadKey(0);
        ReadMode('normal');
        print "$response\n";
        unless (lc($response) eq 'y') {
            $logger->info("Skipped moving $file_path");
            return;
        }
    }

    # Backup before moving
    my $backup_path = File::Spec->catfile($config{backup_dir}, basename($file_path));
    if (!$config{dry_run}) {
        copy($file_path, $backup_path) or $logger->error("Failed to backup $file_path to $backup_path: $!");
    }
    $logger->info("Backed up $file_path to $backup_path") unless $config{dry_run};

    # Move file
    if (!$config{dry_run}) {
        move($file_path, $dest_path) or $logger->error("Failed to move $file_path to $dest_path: $!");
        $logger->info("Moved $file_path to $dest_path");
    } else {
        $logger->info("Dry Run: Would move $file_path to $dest_path");
    }
}

# Subroutine called by File::Find
sub wanted {
    my $file = $File::Find::name;
    # Enqueue file for processing
    $file_queue->enqueue($file) if -f $file;
}

__END__

=pod

=head1 NAME

Directory Organizer - A Comprehensive Perl Script for Managing and Organizing Directories

=head1 SYNOPSIS

perl organizer.pl [options]

 Options:
   --config=s        Specify a configuration file
   --root=s          Set the root directory to organize
   --backup=s        Set the backup directory
   --threads=i       Number of threads to use (default: 4)
   --interactive     Enable interactive mode
   --dry-run         Perform a trial run with no changes made
   --include-hidden  Include hidden files
   --exclude=s       Exclude files matching the pattern

=head1 DESCRIPTION

This script organizes files within a specified root directory into categorized subdirectories based on file extensions. It supports advanced features like multi-threading, logging, backups, and interactive confirmations.

=head1 FEATURES

=over 4

=item * Configurable via command-line and configuration file

=item * Logging of all operations to a log file and screen

=item * Backup of files before moving

=item * Multi-threaded processing for improved performance

=item * Interactive mode for user confirmations

=item * Support for excluding specific files or patterns

=item * Dry-run mode to simulate operations without making changes

=back

=head1 AUTHOR

Anas 2024

=cut
