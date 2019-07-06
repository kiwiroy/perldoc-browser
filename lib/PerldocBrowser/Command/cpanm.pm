package PerldocBrowser::Command::cpanm;

# This software is Copyright (c) 2018 by Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Command';
use Mojo::Util 'getopt';
use Pod::Simple::Search;
use IPC::Run3;
use experimental 'signatures';

has description => 'Install modules using cpanm';
has usage => <<EOF;
Usage: $0 cpanm [--cpanfile <file>] [--cpanm-opt <option>] [all | <version> ...]

Options:

  --cpanfile <cpanfile>  Path to cpanfile                     [cpanfile]
  --cpanm-opt <option>   cpanm options to add to the default (accepts multiple)

  --help   Display this help text
EOF

has cpanfile => sub { Mojo::File->new('cpanfile') };

sub run ($self, @versions) {
  getopt \@versions, 'cpanfile=s' => \my $cpanfile, 'cpanm-opt=s@', \my @extra;
  die $self->usage unless @versions;
  $self->cpanfile(Mojo::File->new($cpanfile)) if $cpanfile;

  if ($versions[0] eq 'all') {
    @versions = @{$self->app->all_perl_versions};
  }
  $cpanfile = $self->cpanfile;
  die "Cannot find cpanfile $cpanfile" if ! -r $cpanfile;

  foreach my $version (@versions) {
    say "Perl version $version";
    $self->app->cpanm_installdeps($version, $cpanfile, @extra);
  }
}



1;
