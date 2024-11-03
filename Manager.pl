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
use IO::Handle;
use Time::Piece;
use Time::HiRes qw(time);
use POSIX qw(strftime);
use File::stat;
use Fcntl ':flock';
use IO::File;
use Scalar::Util qw(looks_like_number);

# ================================
# Initialization and Configuration
# ================================

# Initialize Logger Configuration
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

# Initialize Log4perl
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
    move_on_duplicate => 'rename', # Options: rename, skip, overwrite
    archive_old_files => 1,        # Archive files older than a certain period
    archive_dir       => 'Archive',
    report_file       => 'organizer_report.log',
    max_file_size     => 104857600, # 100 MB
    min_file_size     => 1024,      # 1 KB
    timestamp_format  => '%Y-%m-%d %H:%M:%S',
    retry_attempts    => 3,
    retry_delay       => 5,         # seconds
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
    'Archives_Old'   => qr/^old_/, # Example for specific categorization
    'Others'         => qr/./,       # Catch-all for uncategorized files
);

# ================================
# Command-Line Options Parsing
# ================================

# Parse Command-Line Options
GetOptions(
    'config=s'          => \$config{config_file},
    'root=s'            => \$config{root_dir},
    'backup=s'          => \$config{backup_dir},
    'threads=i'         => \$config{threads},
    'interactive!'      => \$config{interactive},
    'dry-run!'          => \$config{dry_run},
    'include-hidden!'   => \$config{include_hidden},
    'exclude=s'         => \$config{exclude_patterns},
    'move-on-duplicate=s' => \$config{move_on_duplicate},
    'archive-old-files!' => \$config{archive_old_files},
    'archive-dir=s'     => \$config{archive_dir},
    'report-file=s'     => \$config{report_file},
    'max-file-size=i'   => \$config{max_file_size},
    'min-file-size=i'   => \$config{min_file_size},
    'timestamp-format=s'=> \$config{timestamp_format},
    'retry-attempts=i'  => \$config{retry_attempts},
    'retry-delay=i'     => \$config{retry_delay},
) or die "Error in command line arguments\n";

# ================================
# Load Configuration File
# ================================

# Load Configuration File if exists
if (-e $config{config_file}) {
    Config::Simple->import_from($config{config_file}, \%config) or die Config::Simple->error();
    $logger->info("Loaded configuration from $config{config_file}");
}

# Override config with command-line arguments
# Already handled by GetOptions

# Set Log Level
$logger->level($config{log_level});

# ================================
# Directory Setup
# ================================

# Create Backup Directory
unless (-d $config{backup_dir}) {
    make_path($config{backup_dir}) or $logger->fatal("Failed to create backup directory: $!");
    $logger->info("Created backup directory: $config{backup_dir}");
}

# Create Archive Directory if archiving is enabled
if ($config{archive_old_files}) {
    unless (-d $config{archive_dir}) {
        make_path($config{archive_dir}) or $logger->fatal("Failed to create archive directory: $!");
        $logger->info("Created archive directory: $config{archive_dir}");
    }
}

# Create Organizational Directories
foreach my $dir (keys %dir_structure) {
    my $path = File::Spec->catdir($config{root_dir}, $dir);
    unless (-d $path) {
        make_path($path) or $logger->fatal("Failed to create directory $path: $!");
        $logger->info("Created directory: $path");
    }
}

# Create Report File
my $report_fh = IO::File->new(">>$config{report_file}") or $logger->fatal("Cannot open report file: $!");
$report_fh->autoflush(1);

# ================================
# Initialize Queue for Multi-threading
# ================================

my $file_queue = Thread::Queue->new();

# ================================
# Worker Threads Definition
# ================================

# Worker Thread Subroutine
sub worker {
    while (defined (my $file = $file_queue->dequeue())) {
        eval {
            process_file($file);
        };
        if ($@) {
            $logger->error("Error processing file $file: $@");
        }
    }
    threads->exit();
}

# ================================
# Start Worker Threads
# ================================

my @threads;
for (1..$config{threads}) {
    push @threads, threads->create(\&worker);
}

# ================================
# Enqueue Files for Processing
# ================================

find(\&wanted, $config{root_dir});

# Signal threads to finish
$file_queue->end();

# Wait for all threads to finish
$_->join() for @threads;

# Close Report File
$report_fh->close();

print "Directory organization complete.\n";
$logger->info("Directory organization complete.");

# ================================
# Subroutine to Process Each File
# ================================

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

    # Get file information
    my ($filename, $directories, $suffix) = fileparse($file_path, qr/\.[^.]*/);
    my $file_size = -s $file_path;
    my $file_stat = stat($file_path);
    my $mod_time = $file_stat->mtime;
    my $current_time = time;
    my $age = $current_time - $mod_time;

    # Determine category
    my $category = 'Others';
    foreach my $cat (keys %dir_structure) {
        if ($filename =~ $dir_structure{$cat}) {
            $category = $cat;
            last;
        }
    }

    # Handle Archiving of Old Files
    if ($config{archive_old_files} && $category ne 'Archives' && $age > 31536000) { # Older than 1 year
        my $archive_path = File::Spec->catfile($config{archive_dir}, basename($file_path));
        move_with_retry($file_path, $archive_path);
        $logger->info("Archived old file: $file_path to $archive_path");
        log_report("Archived old file: $file_path to $archive_path");
        return;
    }

    # Check file size constraints
    if ($file_size < $config{min_file_size}) {
        $logger->debug("Skipping file smaller than min size: $file_path");
        return;
    }
    if ($file_size > $config{max_file_size}) {
        $logger->debug("Skipping file larger than max size: $file_path");
        return;
    }

    my $dest_dir = File::Spec->catdir($config{root_dir}, $category);
    my $dest_path = File::Spec->catfile($dest_dir, $filename . $suffix);

    # Check for name conflicts
    if (-e $dest_path) {
        if ($config{move_on_duplicate} eq 'rename') {
            my $unique_suffix = "_" . md5_hex(time . rand());
            $dest_path = File::Spec->catfile($dest_dir, $filename . $unique_suffix . $suffix);
            $logger->warn("Name conflict for $filename. Renaming to " . $filename . $unique_suffix . $suffix);
        }
        elsif ($config{move_on_duplicate} eq 'skip') {
            $logger->info("File $filename already exists at destination. Skipping.");
            log_report("Skipped moving $file_path to $dest_path due to existing file.");
            return;
        }
        elsif ($config{move_on_duplicate} eq 'overwrite') {
            $logger->warn("Overwriting existing file: $dest_path");
            # Proceed to overwrite
        }
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
            log_report("Skipped moving $file_path to $dest_path by user choice.");
            return;
        }
    }

    # Backup before moving
    my $backup_path = File::Spec->catfile($config{backup_dir}, basename($file_path));
    if (!$config{dry_run}) {
        copy_with_retry($file_path, $backup_path);
        $logger->info("Backed up $file_path to $backup_path");
        log_report("Backed up $file_path to $backup_path");
    } else {
        $logger->info("Dry Run: Would backup $file_path to $backup_path");
        log_report("Dry Run: Would backup $file_path to $backup_path");
    }

    # Move file
    if (!$config{dry_run}) {
        move_with_retry($file_path, $dest_path);
        $logger->info("Moved $file_path to $dest_path");
        log_report("Moved $file_path to $dest_path");
    } else {
        $logger->info("Dry Run: Would move $file_path to $dest_path");
        log_report("Dry Run: Would move $file_path to $dest_path");
    }
}

# ================================
# Subroutine to Handle File Moving with Retry
# ================================

sub move_with_retry {
    my ($source, $destination) = @_;
    my $attempt = 0;
    while ($attempt < $config{retry_attempts}) {
        if (move($source, $destination)) {
            return 1;
        } else {
            $attempt++;
            $logger->warn("Failed to move $source to $destination. Attempt $attempt of $config{retry_attempts}. Retrying in $config{retry_delay} seconds...");
            sleep($config{retry_delay});
        }
    }
    $logger->error("Failed to move $source to $destination after $config{retry_attempts} attempts.");
    return 0;
}

# ================================
# Subroutine to Handle File Copying with Retry
# ================================

sub copy_with_retry {
    my ($source, $destination) = @_;
    my $attempt = 0;
    while ($attempt < $config{retry_attempts}) {
        if (copy($source, $destination)) {
            return 1;
        } else {
            $attempt++;
            $logger->warn("Failed to copy $source to $destination. Attempt $attempt of $config{retry_attempts}. Retrying in $config{retry_delay} seconds...");
            sleep($config{retry_delay});
        }
    }
    $logger->error("Failed to copy $source to $destination after $config{retry_attempts} attempts.");
    return 0;
}

# ================================
# Subroutine for Logging Reports
# ================================

sub log_report {
    my ($message) = @_;
    my $timestamp = localtime->strftime($config{timestamp_format});
    $report_fh->print("[$timestamp] $message\n");
}

# ================================
# Subroutine Called by File::Find
# ================================

sub wanted {
    my $file = $File::Find::name;
    # Enqueue file for processing
    $file_queue->enqueue($file) if -f $file;
}

# ================================
# Additional Functionalities
# ================================

# Subroutine to Generate Summary Report
sub generate_summary_report {
    my $total_files = 0;
    my %category_count;
    my %file_size_distribution;

    find(sub {
        return unless -f;
        $total_files++;
        my ($filename, $directories, $suffix) = fileparse($_, qr/\.[^.]*/);
        my $category = 'Others';
        foreach my $cat (keys %dir_structure) {
            if ($filename =~ $dir_structure{$cat}) {
                $category = $cat;
                last;
            }
        }
        $category_count{$category}++;
        my $size = -s $_;
        if ($size < 1024) {
            $file_size_distribution{'<1KB'}++;
        }
        elsif ($size < 1048576) {
            $file_size_distribution{'1KB-1MB'}++;
        }
        elsif ($size < 10485760) {
            $file_size_distribution{'1MB-10MB'}++;
        }
        else {
            $file_size_distribution{'>10MB'}++;
        }
    }, $config{root_dir});

    # Log Summary
    $logger->info("===== Summary Report =====");
    $logger->info("Total files processed: $total_files");
    foreach my $cat (sort keys %category_count) {
        $logger->info("Category '$cat': $category_count{$cat} files");
    }
    $logger->info("File Size Distribution:");
    foreach my $range (sort keys %file_size_distribution) {
        $logger->info("  $range: $file_size_distribution{$range} files");
    }
    $logger->info("===== End of Report =====");
    log_report("Summary Report Generated: Total files - $total_files");
}

# Generate Summary Report at the end
generate_summary_report();

# ================================
# Additional Enhancements and Comments
# ================================

=begin comment

This Perl script is a comprehensive directory organizer designed to manage and organize files within a specified root directory. It categorizes files based on their extensions, handles backups, manages duplicates, archives old files, and generates detailed reports. The script employs multi-threading to enhance performance and includes robust error handling to ensure reliability.

Key Features:
1. **Configuration Management**: Supports both command-line arguments and configuration files for flexible setup.
2. **Logging**: Utilizes Log::Log4perl for detailed logging to both a file and the screen.
3. **Multi-threading**: Implements worker threads to process files concurrently, improving efficiency.
4. **Backup and Archiving**: Automatically backs up files before moving and archives files older than a specified period.
5. **Duplicate Handling**: Offers options to rename, skip, or overwrite files in case of name conflicts.
6. **Interactive Mode**: Allows user confirmations before moving files, providing control over the process.
7. **File Size Constraints**: Skips files that are too small or too large based on configurable thresholds.
8. **Reporting**: Generates a summary report detailing the number of files processed, categorized counts, and size distributions.

Future Enhancements:
- **GUI Interface**: Develop a graphical user interface for easier configuration and monitoring.
- **Database Integration**: Integrate with a database to keep track of file movements and maintain a history.
- **Email Notifications**: Send email alerts upon completion or in case of errors.
- **Advanced Categorization**: Incorporate machine learning to categorize files based on content.
- **Scheduling**: Allow the script to run at scheduled intervals using cron jobs or a built-in scheduler.

=end comment

# ================================
# POD Documentation
# ================================

=pod

=head1 NAME

Directory Organizer - A Comprehensive Perl Script for Managing and Organizing Directories

=head1 SYNOPSIS

    perl organizer.pl [options]

    Options:
      --config=s            Specify a configuration file
      --root=s              Set the root directory to organize
      --backup=s            Set the backup directory
      --threads=i           Number of threads to use (default: 4)
      --interactive         Enable interactive mode
      --dry-run             Perform a trial run with no changes made
      --include-hidden      Include hidden files
      --exclude=s           Exclude files matching the pattern
      --move-on-duplicate=s  How to handle duplicates: rename, skip, overwrite
      --archive-old-files   Enable archiving of old files
      --archive-dir=s       Set the archive directory
      --report-file=s       Set the report file path
      --max-file-size=i     Set maximum file size in bytes (default: 104857600)
      --min-file-size=i     Set minimum file size in bytes (default: 1024)
      --timestamp-format=s  Set the timestamp format for reports (default: '%Y-%m-%d %H:%M:%S')
      --retry-attempts=i    Number of retry attempts for failed operations (default: 3)
      --retry-delay=i       Delay in seconds between retry attempts (default: 5)

=head1 DESCRIPTION

This script organizes files within a specified root directory into categorized subdirectories based on file extensions. It supports advanced features like multi-threading, logging, backups, archiving, and interactive confirmations.

=head1 FEATURES

=over 4

=item * Configurable via command-line and configuration file

=item * Logging of all operations to a log file and screen

=item * Backup of files before moving

=item * Archiving of files older than a specified period

=item * Multi-threaded processing for improved performance

=item * Interactive mode for user confirmations

=item * Support for excluding specific files or patterns

=item * Handling of duplicate files with options to rename, skip, or overwrite

=item * File size constraints to skip files that are too small or too large

=item * Summary report generation detailing processed files and categories

=back

=head1 USAGE

=head2 Basic Usage

To run the script with default settings:

    perl organizer.pl

=head2 Using a Configuration File

Create a configuration file (e.g., organizer.conf) with desired settings:

    root_dir = "/path/to/your/root"
    backup_dir = "/path/to/your/backup"
    log_level = "INFO"
    threads = 8
    interactive = 1
    include_hidden = 1
    dry_run = 0
    exclude_patterns = "\.tmp$|\.log$"
    move_on_duplicate = "rename"
    archive_old_files = 1
    archive_dir = "/path/to/archive"
    report_file = "organizer_report.log"
    max_file_size = 104857600
    min_file_size = 1024
    timestamp_format = "%Y-%m-%d %H:%M:%S"
    retry_attempts = 3
    retry_delay = 5

Run the script with the configuration file:

    perl organizer.pl --config=organizer.conf

=head2 Command-Line Overrides

You can override configuration file settings using command-line options:

    perl organizer.pl --root=/new/root --backup=/new/backup --threads=4 --interactive

=head2 Dry Run Mode

To simulate actions without making any changes:

    perl organizer.pl --dry-run

=head2 Interactive Mode

Enable interactive confirmations before moving each file:

    perl organizer.pl --interactive

=head1 AUTHOR

Anas 2024

=head1 LICENSE

This script is released under the MIT License.

=head1 BUGS AND LIMITATIONS

Please report any bugs or feature requests to [your email or repository link].

=head1 SUPPORT

For support, please contact [your contact information].

=head1 ACKNOWLEDGEMENTS

Thanks to all contributors and the open-source community for their invaluable resources and support.

This Management File Is Written in the programming language perl by Anas 2024 Sun Nov 3 

=cut
