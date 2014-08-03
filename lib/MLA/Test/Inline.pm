package MLA::Test::Inline;

# TODO: when checking if tests need updating, check when the last modification
# of this module happened. If it's later than the test timestamp, go ahead
# and regenerate (since the inline code logic itself may have changed).

# See Test::Inline

#{{{ test
=begin testing

   use_ok $CLASS;

=end testing
=cut
#}}}

use strict;
use utf8;
use autodie qw/ :all /;
use Carp;
use Cwd qw/ cwd /;
use File::Slurp qw/ read_file /;
use File::Spec;
use Readonly;
use Test::Inline::Extract;
use Test::Inline::Script;
use Test::Inline::Section;
use Time::HiRes qw/ stat /;


# See Test::Inline::Content
Readonly my $DEFAULT_TEMPLATE => <<'EOF';
#!/usr/bin/env perl

# Automatically generated file; changes will be lost!
# 
# source: [% source_path %]

use strict;
use warnings;
no warnings 'uninitialized';
use lib 'lib';
use utf8;
use Carp;
use autodie qw/ :all /;
use Test::Deep;
use Test::Differences;
use Test::Exception;
use Test::More;
use Test::Output;
use Test::Warn;

$| = 1;

my $CLASS = '[% class %]';
my $SOURCE_PATH = '[% source_path %]';

[% tests %]

# prevent "semicolon seems to be missing" error if test block only has comment
;

Test::More::done_testing([% num_tests %]);

1;

EOF


=begin testing
  
   my @list = qw/ a b c /;
   is_deeply [ $CLASS->_list ], [], 'empty list';
   is_deeply [ $CLASS->_list(@list), ], \@list, '_list';
   is_deeply [ $CLASS->_list(\@list) ], \@list, '_list arrayref flattened';
   is_deeply [ $CLASS->_list(@list, \@list) ], [@list, @list], '_list multi';

=end testing

=cut 

#}}}

sub _list {
  my $class = shift;

  return map { ref $_ eq 'ARRAY' ? @$_ : $_ } @_;
}


#{{{ test
=begin testing

   my $tmpdir = $t->tmpdir;
   chdir $tmpdir;

   $t->writefile('target', 'a');
   $t->writefile('src1', 'b');
   $t->writefile('src2', 'c');

   eval { $CLASS->_modified_since };
   ok $@, '_modified_since requires target';

   eval { $CLASS->_modified_since('a') };
   ok $@, '_modified_since requires one or more source files';

   eval { $CLASS->_modified_since('a', undef, '') };
   ok $@, '_modified_since undefined and blank sources do not count';

   # make sure all mtime's are the same
   my $time = time;
   utime $time, $time, qw/ target src1 src2 /;

   ok $CLASS->_modified_since('non-existent', 'src1'),
     '_modified_since, missing target file always returns modified';

   eval { $CLASS->_modified_since('target', 'non-existent') };
   ok $@, 'missing source file raises exception';

   ok $CLASS->_modified_since('target', 'src1'),
     '_modified_since, matching mtime treated as modified';

   ok $CLASS->_modified_since('target', [qw/ src1 src2 /]),
     '_modified_since, source as array ref';

   # reset src1's mtime to past
   utime $time - 60, $time - 60, 'src1';
   ok ! $CLASS->_modified_since('target', 'src1'),
     '_modified_since, not modified';

   ok $CLASS->_modified_since('target', 'src1', 'src2'),
     '_modified_since, modified if any source file is newer';

=end testing
=cut
#}}}

sub _modified_since {
  my $class = shift;
  my $target = shift or croak "no target file supplied";
  my @sources = grep { defined and length } $class->_list(@_);

  @sources or croak "no file dependencies supplied";

  -f $target or return 1;
  my $target_mtime = (stat $target)[9];

  #warn "target '$target' mtime: $target_mtime\n";
  foreach my $source (@sources) {
    -f $source or croak "source file '$source' not found";
    # warn "source '$source' mtime: ", (stat $source)[9], "\n";
    return 1 if (stat $source)[9] >= $target_mtime;
  }

  return;
}


#{{{ test
=begin testing

   eval { $CLASS->_generate_package_name };
   ok $@, '_generate_package_name requires path';

   is $CLASS->_generate_package_name('Foo'), 'Foo';
   is $CLASS->_generate_package_name('Foo/Two.pm'), 'Foo::Two_2epm';
   is $CLASS->_generate_package_name('/Foo/12.pm'), 'Foo::_312_2epm';

=end testing
=cut
#}}}

# Take a Unix filesystem path and convert it to a legal perl package name.
# See also perlvar.
sub _generate_package_name {
  my $class = shift;
  my $path = shift or croak "no path supplied";

  $path =~ s{^/+}{}; # remove any leading slashes

  # Escape everything into valid perl identifiers
  $path =~ s/([^A-Za-z0-9_\/])/sprintf("_%02x", ord $1)/eg;

  # second pass cares for slashes and words starting with a digit
  $path =~
    s{ (/+)(\d?) }
     { '::' . (length $2 ? sprintf("_%02x", ord $2) : '') }egx;

  return $path;
}


#{{{ test
=begin testing

   my $tmpdir = $t->tmpdir;
   chdir $tmpdir;

   $t->writefile('no_tests', 'abc');

   eval { $CLASS->build_test };
   ok $@, 'build_test, requires source';

   eval { $CLASS->build_test('non-existing') };
   ok $@, 'build_test, missing source path raises exception';

   is $CLASS->build_test('no_tests'), undef,
     'build_test, returns false if no tests found';

   my $source = qq{
     #!/usr/bin/env perl
     
     use strict;
     use utf8;
     
     =begin testing

       ok 1, 'true is true';

     =end testing
     =cut


     =begin testing

       ok !0, 'false is false';

     =end testing
     =cut
   };
   $source =~ s/^[ ]+(.*?)/$1/gm;

   $t->writefile('script', "$source\n");
   my $data = $t->readfile('script');
   ok $CLASS->build_test('script');

   # if root_dir supplied, tries to make test package names relative to it
   ok $CLASS->build_test('script', root_dir => $tmpdir);

   my $script = $CLASS->build_test($SOURCE_PATH);
   ok ref $script, 'build_test, positional param';

   $script = $CLASS->build_test(source_path => $SOURCE_PATH);
   ok ref $script, 'build_test, named param';

=end testing
=cut
#}}}

sub build_test {
  my $class = shift;
  my %args = (@_ % 2 ? (source_path => @_) : @_);

  my $source_path = $args{source_path} or croak "no source_path supplied";
  -f $source_path or croak "test input file '$source_path' not found";
  my $source = read_file($source_path);

  my $extract = Test::Inline::Extract->new(\$source)
    or croak "unable to create inline extraction object";
  my $elements = $extract->elements or return;

  my $sections = Test::Inline::Section->parse($elements);

  # If not a module, add package name
  my $package;
  foreach (@$sections) {
    $_->{context} ||=
      $package ||= do {
        $class->_generate_package_name($source_path);
      };

    $package ||= $_->{context};
  }
  $package or croak "no package name determined";

  my $script = Test::Inline::Script->new($package, $sections)
    or croak "unable to create Inline::Script instance";

  return $script; # instance
}


#{{{ test
=begin testing

  my $script = $CLASS->build_test($SOURCE_PATH);
  ok $script;

  eval { $CLASS->_apply_template };
  ok $@, '_apply_template, script object required';

  eval { $CLASS->_apply_template(script => $script) };
  ok $@, '_apply_template, source path required';

  ok $CLASS->_apply_template(script => $script, source_path => $SOURCE_PATH),
    '_apply_template, named param';

  my $code = $CLASS->_apply_template(
    script => $script,
    source_path => $SOURCE_PATH,
    template => 'foo',
  );
  is $code, 'foo', '_apply_template, with supplied template';

=end testing
=cut
#}}}

# Insert the test code and a few dynamic values using a simple [% VAR %]
# templating syntax. See the $DEFAULT_TEMPLATE for an example.
sub _apply_template {
  my $class = shift;
  my %args = @_;

  my $script = delete $args{script} or croak "no script object supplied";
  $args{source_path} or croak "no source_path supplied";
  my $code = delete $args{template} || $DEFAULT_TEMPLATE;

  $args{tests} = $script->merged_content;
  $args{num_tests} = $script->tests;
  $args{class} = $script->class; # class being tested

  $args{source_path} = File::Spec->abs2rel(
    $args{source_path},
    $args{root_path} // '',
  ); 

  $code =~ s/\[% \s+ (\S+) \s+ %]/$args{ $1 }/gxe;

  return $code;
}


#{{{ test
=begin testing

   use File::Basename qw/ basename /;
   use File::Copy qw/ copy /;

   my $tmpdir = $t->tmpdir;
   chdir $tmpdir;

   my $basename = basename $SOURCE_PATH;
   copy $SOURCE_PATH, $tmpdir
     or croak "copy '$SOURCE_PATH' to '$tmpdir/' failed: $!";
   my $source = "$tmpdir/$basename";
   -f $source or croak "failed to copy source to temp directory";

   # Age the source file a bit so it looks like tests need updating
   my $time = time - 100;
   utime $time, $time, $source;


   eval { $CLASS->write_test };
   ok $@, 'write_test, requires source';

   eval { $CLASS->write_test(source_path => $source) };
   ok $@, 'write_test, requires test_dir';

   my $wrongdir = "$tmpdir/not-exists";
   eval { $CLASS->write_test(source_path => $source, test_dir => $wrongdir) };
   ok $@, 'write_test, non-existing test dir raises exception';

   my $write_test = sub {
     $CLASS->write_test(source_path => $source, test_dir => $tmpdir, @_)
   };

   my ($test_path, $updated) = $write_test->();
   ok $test_path && $updated, 'write_test';

   ($test_path, $updated) = $write_test->();
   ok $test_path && !$updated, 'write_test, unmodified';

   foreach (qw/ force refresh /) {
     ($test_path, $updated) = $write_test->($_ => 1);
     ok $test_path && $updated, 'write_test, update forced';
   }

   my $test_path2 = $write_test->();
   is $test_path2, $test_path, 'write_test, scalar context';

   $t->touch($source);
   ($test_path, $updated) = $write_test->();
   ok $test_path && $updated, 'write_test, source modified';

=end testing
=cut
#}}}

sub write_test {
  my $class = shift;
  my %args = @_;

  my $source = $args{source_path} or croak "no source_path supplied";
  my $test_dir = $args{test_dir} or croak "no test_dir supplied";

  -f $source or croak "test input file '$source' not found";
  -d $test_dir or croak "output directory '$test_dir' does not exist";

  my $script = $class->build_test(%args) or return;

  my $test_path = File::Spec->catfile($test_dir, $script->filename);

  my $updated = 1;
  unless ($args{force} || $args{refresh}) {
    $updated = 0 unless $class->_modified_since($test_path, $source);
  }

  if ($updated) {
    my $code = $class->_apply_template(
      script => $script,
      source_path => $source,
    );

    open my $fh, '>', $test_path;
    print $fh $code;
    close $fh;
  }

  return wantarray ? ($test_path, $updated) : $test_path;
}


1;

__END__

=head1 NAME

MLA::Test::Inline -

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item build_test

=item write_test

=back

=head1 AUTHOR

Maurice Aubrey

=head1 SEE ALSO

=cut

# vim: set foldmethod=marker:
