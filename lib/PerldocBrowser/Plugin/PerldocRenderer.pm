package PerldocBrowser::Plugin::PerldocRenderer;

# This software is Copyright (c) 2008-2018 Sebastian Riedel and others, 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use List::Util 'first';
use MetaCPAN::Pod::XHTML;
use Module::Metadata;
use Mojo::ByteStream;
use Mojo::DOM;
use Mojo::File 'path';
use Mojo::URL;
use Mojo::Util qw(trim url_unescape);
use Pod::Simple::Search;
use Pod::Simple::TextContent;
use Scalar::Util 'weaken';
use experimental 'signatures';

sub register ($self, $app, $conf) {
  $app->helper(split_functions => sub ($c, @args) { _split_functions(@args) });
  $app->helper(split_variables => sub ($c, @args) { _split_variables(@args) });
  $app->helper(split_faqs => sub ($c, @args) { _split_faqs(@args) });
  $app->helper(split_perldelta => sub ($c, @args) { _split_perldelta(@args) });
  $app->helper(pod_to_html => sub ($c, @args) { _pod_to_html(@args) });
  $app->helper(pod_to_text_content => sub ($c, @args) { _pod_to_text_content(@args) });
  $app->helper(escape_pod => sub ($c, @args) { _escape_pod(@args) });
  $app->helper(append_url_path => sub ($c, @args) { _append_url_path(@args) });
  $app->helper(prepare_perldoc_html => \&_prepare_html);
  $app->helper(render_perldoc_html => \&_render_html);

  my $homepage = $app->config('homepage') // 'perl';
  my %defaults = (
    module => $homepage,
    perl_version => $app->latest_perl_version,
    url_perl_version => '',
  );

  foreach my $perl_version (@{$app->all_perl_versions}) {
    $app->routes->any("/$perl_version/functions/:function"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'functions'}
      => [function => qr/[^.]+/] => \&_function);
    $app->routes->any("/$perl_version/variables/:variable"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'perlvar'}
      => [variable => qr/[^.]+(?:\.{3}[^.]+|\.)?/] => \&_variable);
    $app->routes->any("/$perl_version/functions"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'functions'}
      => \&_functions_index);
    $app->routes->any("/$perl_version/modules"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version, module => 'modules'}
      => \&_modules_index);
    $app->routes->any("/$perl_version/:module"
      => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version}
      => [module => qr/[^.]+(?:\.[0-9]+)*/] => \&_perldoc);
  }

  $app->routes->any("/functions/:function" => {%defaults, module => 'functions'} => [function => qr/[^.]+/] => \&_function);
  $app->routes->any("/variables/:variable" => {%defaults, module => 'perlvar'} => [variable => qr/[^.]+(?:\.{3}[^.]+|\.)?/] => \&_variable);
  $app->routes->any("/functions" => {%defaults, module => 'functions'} => \&_functions_index);
  $app->routes->any("/modules" => {%defaults, module => 'modules'} => \&_modules_index);
  $app->routes->any("/:module" => {%defaults} => [module => qr/[^.]+(?:\.[0-9]+)*/] => \&_perldoc);
}

sub _find_pod($c, $module) {
  my $inc_dirs = $c->inc_dirs($c->stash('perl_version'));
  return Pod::Simple::Search->new->inc(0)->find($module, @$inc_dirs);
}

sub _find_module($c, $module) {
  my $inc_dirs = $c->inc_dirs($c->stash('perl_version'));
  my $meta;
  { local $@;
    $c->app->log->debug("Error retrieving module metadata for $module: $@")
      unless eval { $meta = Module::Metadata->new_from_module($module, inc => $inc_dirs); 1 };
  }
  return $meta;
}

sub _prepare_html ($c, $src) {
  my $url_perl_version = $c->stash('url_perl_version');
  my $dom = Mojo::DOM->new($c->pod_to_html($src, $url_perl_version));

  my $module = $c->stash('module');
  my $function = $c->stash('function');
  my $variable = $c->stash('variable');

  # Rewrite code blocks for syntax highlighting and correct indentation
  for my $e ($dom->find('pre > code')->each) {
    next if (my $str = $e->all_text) =~ /^\s*(?:\$|Usage:)\s+/m;
    next unless $str =~ /[\$\@\%]\w|->\w|[;{]\s*(?:#|$)/m;
    my $attrs = $e->attr;
    my $class = $attrs->{class};
    $attrs->{class} = defined $class ? "$class prettyprint" : 'prettyprint';
  }

  my $url_prefix = $url_perl_version ? $c->append_url_path('/', $url_perl_version) : '';

  if ($module eq 'functions') {
    # Rewrite links on function pages
    for my $e ($dom->find('a[href]')->each) {
      my $link = Mojo::URL->new($e->attr('href'));
      next if length $link->path;
      next unless length(my $fragment = $link->fragment);
      my ($function) = $fragment =~ m/^(.[^-]*)/;
      $e->attr(href => $c->url_for($c->append_url_path("$url_prefix/functions/", $function)));
    }

    # Insert links on functions index
    if (!defined $function) {
      for my $e ($dom->find(':not(a) > code')->each) {
        my $text = $e->all_text;
        $e->wrap($c->link_to('' => $c->url_for($c->append_url_path("$url_prefix/functions/", "$1"))))
          if $text =~ m/^([-\w]+)\/*$/ or $text =~ m/^([-\w\/]+)$/;
      }
    }
  }

  # Rewrite links on variable pages
  if (defined $variable) {
    for my $e ($dom->find('a[href]')->each) {
      my $link = Mojo::URL->new($e->attr('href'));
      next if length $link->path;
      next unless length (my $fragment = $link->fragment);
      if ($fragment =~ m/^[\$\@%]/ or $fragment =~ m/^[a-zA-Z]+$/) {
        $e->attr(href => $c->url_for($c->append_url_path("$url_prefix/variables/", $fragment)));
      } else {
        $e->attr(href => $c->url_for(Mojo::URL->new("$url_prefix/perlvar")->fragment($fragment)));
      }
    }
  }

  # Insert links on modules list
  if ($module eq 'modules') {
    for my $e ($dom->find('dt')->each) {
      my $module = $e->all_text;
      $e->child_nodes->last->wrap($c->link_to('' => $c->url_for($c->append_url_path("$url_prefix/", $module))));
    }
  }

  # Insert links on perldoc perl
  if ($module eq 'perl') {
    for my $e ($dom->find('pre > code')->each) {
      my $str = $e->content;
      $e->content($str) if $str =~ s/^\s*\K(perl\S+)/$c->link_to("$1" => $c->url_for($c->append_url_path("$url_prefix\/", "$1")))/mge;
    }
    for my $e ($dom->find(':not(pre) > code')->each) {
      my $text = $e->all_text;
      $e->wrap($c->link_to('' => $c->url_for($c->append_url_path("$url_prefix/", "$1")))) if $text =~ m/^perldoc (\w+)$/;
      $e->content($text) if $text =~ s/^use \K([a-z]+)(;|$)/$c->link_to("$1" => $c->url_for($c->append_url_path("$url_prefix\/", "$1"))) . $2/e;
    }
    for my $e ($dom->find('p > b')->each) {
      my $text = $e->all_text;
      $e->content($text) if $text =~ s/^use \K([a-z]+)(;|$)/$c->link_to("$1" => $c->url_for($c->append_url_path("$url_prefix\/", "$1"))) . $2/e;
    }
  }

  if ($module eq 'search') {
    # Rewrite links to function pages
    for my $e ($dom->find('a[href]')->each) {
      next unless $e->attr('href') =~ /^[^#]+perlfunc#(.[^-]*)/;
      my $function = url_unescape "$1";
      $e->attr(href => $c->url_for($c->append_url_path("$url_prefix/functions/", $function)))->content($function);
    }
  }

  return $dom;
}

sub _render_html ($c, $dom) {
  # Try to find a title
  my $title = $c->stash('page_name') // $c->stash('module');
  $dom->find('h1')->first(sub {
    return unless $_->all_text eq 'NAME';
    my $p = $_->next;
    return unless $p->tag eq 'p';
    $title = $p->all_text;
  });

  # Rewrite headers
  my %level = (h1 => 1, h2 => 2, h3 => 3, h4 => 4);
  my $linkable = 'h1, h2, h3, h4';
  $linkable .= ', dt' unless $c->stash('module') eq 'search';
  my (@toc, $parent);
  for my $e ($dom->find($linkable)->each) {
    my $link = Mojo::URL->new->fragment($e->{id});
    my $text = $e->all_text;
    unless ($e->tag eq 'dt') {
      my $entry = {tag => $e->tag, text => $text, link => $link};
      $parent = $parent->{parent} until !defined $parent
        or $level{$e->tag} > $level{$parent->{tag}};
      if (defined $parent) {
        weaken($entry->{parent} = $parent);
        push @{$parent->{contents}}, $entry;
      } else {
        push @toc, $entry;
      }
      $parent = $entry;
    }
    my $permalink = $c->link_to('#' => $link, class => 'permalink');
    $e->content($permalink . $e->content);
  }

  # Combine everything to a proper response
  $c->content_for(perldoc => "$dom");
  $c->render('perldoc', title => $title, toc => \@toc);
}

sub _perldoc ($c) {
  # Find module or redirect to CPAN
  my $module = $c->stash('module');
  $c->stash(page_name => $module);
  $c->stash(cpan => $c->append_url_path('https://metacpan.org/pod', $module));

  my $path = _find_pod($c, $module);
  return $c->res->code(301) && $c->redirect_to($c->stash('cpan')) unless $path && -r $path;
  
  $c->respond_to(
    txt => sub { $c->render(data => path($path)->slurp) },
    html => sub {
      if (defined(my $module_meta = _find_module($c, $module))) {
        $c->stash(module_version => $module_meta->version($module));
      }

      if (defined $c->app->search_backend) {
        my $function = $c->function_name_match($c->stash('perl_version'), $module);
        $c->stash(alt_page_type => 'function', alt_page_name => $function) if defined $function;
      }

      $c->render_perldoc_html($c->prepare_perldoc_html(path($path)->slurp));
    },
  );
}

sub _function ($c) {
  my $function = $c->stash('function');
  $c->stash(page_name => $function);
  $c->stash(cpan => Mojo::URL->new('https://metacpan.org/pod/perlfunc')->fragment($function));

  my $src = _get_function_pod($c, $function);
  return $c->res->code(301) && $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(
    txt => {data => $src},
    html => sub {
      my $heading = first { m/^=item/ } split /\n\n+/, $src;
      if (defined $heading) {
        my $target = $c->pod_to_text_content(join "\n\n", '=over', $heading, '=back');
        my $escaped = $c->escape_pod($target);
        my $link = Mojo::DOM->new($c->pod_to_html(qq{=pod\n\nL<< /"$escaped" >>}))->at('a');
        if (defined $link) {
          my $fragment = Mojo::URL->new($link->attr('href'))->fragment;
          $c->stash(cpan => Mojo::URL->new('https://metacpan.org/pod/perlfunc')->fragment($fragment));
        }
      }

      if (defined $c->app->search_backend) {
        my $pod = $c->pod_name_match($c->stash('perl_version'), $function);
        $c->stash(alt_page_type => 'module', alt_page_name => $pod) if defined $pod;
      }

      $c->render_perldoc_html($c->prepare_perldoc_html($src));
    },
  );
}

sub _variable ($c) {
  my $variable = $c->stash('variable');
  $c->stash(page_name => $variable);
  my $escaped = $c->escape_pod($variable);
  my $link = Mojo::DOM->new($c->pod_to_html(qq{=pod\n\nL<< /"$escaped" >>}))->at('a');
  my $fragment = defined $link ? Mojo::URL->new($link->attr('href'))->fragment : $variable;
  $c->stash(cpan => Mojo::URL->new('https://metacpan.org/pod/perlvar')->fragment($fragment));

  my $src = _get_variable_pod($c, $variable);
  return $c->res->code(301) && $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(
    txt => {data => $src},
    html => sub { $c->render_perldoc_html($c->prepare_perldoc_html($src)) },
  );
}

sub _functions_index ($c) {
  $c->stash(page_name => 'functions');
  $c->stash(cpan => 'https://metacpan.org/pod/perlfunc#Perl-Functions-by-Category');

  my $src = _get_function_categories($c);
  return $c->res->code(301) && $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(
    txt => {data => $src},
    html => sub { $c->render_perldoc_html($c->prepare_perldoc_html($src)) },
  );
}

sub _modules_index ($c) {
  $c->stash(page_name => 'modules');
  $c->stash(cpan => 'https://metacpan.org');

  my $src = _get_module_list($c);
  return $c->res->code(301) && $c->redirect_to($c->stash('cpan')) unless defined $src;

  $c->respond_to(
    txt => {data => $src},
    html => sub { $c->render_perldoc_html($c->prepare_perldoc_html($src)) },
  );
}

sub _get_function_pod ($c, $function) {
  my $path = _find_pod($c, 'perlfunc');
  return undef unless $path && -r $path;
  my $src = path($path)->slurp;

  my $result = $c->split_functions($src, $function);
  return undef unless @$result;
  return join "\n\n", '=over', @$result, '=back';
}

sub _get_variable_pod ($c, $variable) {
  my $path = _find_pod($c, 'perlvar');
  return undef unless $path && -r $path;
  my $src = path($path)->slurp;

  my $result = $c->split_variables($src, $variable);
  return undef unless @$result;
  return join "\n\n", '=over', @$result, '=back';
}

sub _get_function_categories ($c) {
  my $path = _find_pod($c, 'perlfunc');
  return undef unless $path && -r $path;
  my $src = path($path)->slurp;

  my ($started, @result);
  foreach my $para (split /\n\n+/, $src) {
    if (!$started and $para =~ m/^=head\d Perl Functions by Category/) {
      $started = 1;
      push @result, '=pod';
    } elsif ($started) {
      last if $para =~ m/^=head/;
      push @result, $para;
    }
  }

  return undef unless @result;
  return join "\n\n", @result;
}

sub _get_module_list ($c) {
  my $path = _find_pod($c, 'perlmodlib');
  return undef unless $path && -r $path;
  my $src = path($path)->slurp;

  my ($started, $standard, @result);
  foreach my $para (split /\n\n+/, $src) {
    if (!$started and $para =~ m/^=head\d Pragmatic Modules/) {
      $started = 1;
      push @result, $para;
    } elsif ($started) {
      $standard = 1 if $para =~ m/^=head\d Standard Modules/;
      push @result, $para;
      last if $standard and $para =~ m/^=back/;
    }
  }

  return undef unless @result;
  return join "\n\n", @result;
}

# Edge cases: eval, do, chop, y///, -X, getgrent, __END__
sub _split_functions ($src, $function = undef) {
  my $list_level = 0;
  my $found = '';
  my ($started, $filetest_section, $found_filetest, @function, @functions);

  foreach my $para (split /\n\n+/, $src) {
    $started = 1 if !$started and $para =~ m/^=head\d Alphabetical Listing of Perl Functions/;
    next unless $started;
    next if $para =~ m/^=for Pod::Functions/;

    # keep track of list depth
    if ($para =~ m/^=over/) {
      $list_level++;
      next if $list_level == 1;
    }
    if ($para =~ m/^=back/) {
      $list_level--;
      $found = 'end' if $found and $list_level == 0;
    }

    # functions are only declared at depth 1
    my ($is_header, $is_function_header);
    if ($list_level == 1) {
      $is_header = 1 if $para =~ m/^=item/;
      if ($is_header) {
        # new function heading
        if (defined $function) {
          my $heading = _pod_to_text_content("=over\n\n$para\n\n=back");
          # check -X section later for filetest operators
          $filetest_section = 1 if !$found and $heading =~ m/^-X\b/ and $function =~ m/^-[a-zA-WYZ]$/;
          # see if this is the start or end of the function we want
          $is_function_header = 1 if $heading =~ m/^\Q$function\E(\W|$)/;
          $found = 'header' if !$found and $is_function_header;
          $found = 'end' if $found eq 'content' and !$is_function_header;
        } else {
          # this indicates a new function section if we found content
          $found = 'header' if !$found;
          $found = 'end' if $found eq 'content';
        }
      } elsif ($found eq 'header' or $filetest_section) {
        # function content if we're in a function section
        $found = 'content' unless $found eq 'end';
      } elsif (!$found and defined $function) {
        # skip content if this isn't the function section we're looking for
        @function = ();
        next;
      }
    }

    if ($found eq 'end') {
      if (defined $function) {
        # we're done, unless we were checking the -X section for filetest operators and didn't find it
        last unless $filetest_section and !$found_filetest;
      } else {
        # add this function section
        push @functions, [@function];
      }
      # start next function section
      @function = ();
      $filetest_section = 0;
      $found = $is_header && (!defined $function or $is_function_header) ? 'header' : '';
    }

    # function contents at depth 1+
    if ($list_level >= 1) {
      # check -X section content for filetest operators
      $found_filetest = 1 if $filetest_section and $para =~ m/^\s+\Q$function\E\s/m;
      # add content to function section
      push @function, $para;
    }
  }

  return defined $function ? \@function : \@functions;
}

sub _split_variables ($src, $variable = undef) {
  my $list_level = 0;
  my $found = '';
  my ($started, @variable, @variables);

  foreach my $para (split /\n\n+/, $src) {
    # keep track of list depth
    if ($para =~ m/^=over/) {
      $list_level++;
      next if $list_level == 1;
    }
    if ($para =~ m/^=back/) {
      $list_level--;
      $found = 'end' if $found and $list_level == 0;
    }

    # variables are only declared at depth 1
    my ($is_header, $is_variable_header);
    if ($list_level == 1) {
      $is_header = 1 if $para =~ m/^=item/;
      if ($is_header) {
        if (defined $variable) {
          my $heading = _pod_to_text_content("=over\n\n$para\n\n=back");
          # see if this is the start or end of the variable we want
          $is_variable_header = 1 if $heading eq $variable;
          $found = 'header' if !$found and $is_variable_header;
          $found = 'end' if $found eq 'content' and !$is_variable_header;
        } else {
          # this indicates a new variable section if we found content
          $found = 'header' if !$found;
          $found = 'end' if $found eq 'content';
        }
      } elsif ($found eq 'header') {
        # variable content if we're in a variable section
        $found = 'content' unless $found eq 'end';
      } elsif (!$found and defined $variable) {
        # skip content if this isn't the variable section we're looking for
        @variable = ();
        next;
      }
    }

    if ($found eq 'end') {
      if (defined $variable) {
        # we're done
        last;
      } else {
        # add this variable section
        push @variables, [@variable];
      }
      # start next variable section
      @variable = ();
      $found = $is_header && (!defined $variable or $is_variable_header) ? 'header' : '';
    }

    # variable contents at depth 1+
    push @variable, $para if $list_level >= 1;
  }

  return defined $variable ? \@variable : \@variables;
}

sub _split_faqs ($src, $question = undef) {
  my $found = '';
  my ($started, @faq, @faqs);

  foreach my $para (split /\n\n+/, $src) {
    $found = 'end' if $found and $para =~ m/^=head1/;

    my ($is_header, $is_question_header);
    $is_header = 1 if $para =~ m/^=head2/;
    if ($is_header) {
      if (defined $question) {
        my $heading = _pod_to_text_content("=pod\n\n$para");
        # see if this is the start or end of the question we want
        $is_question_header = 1 if $heading eq $question;
        $found = 'header' if !$found and $is_question_header;
        $found = 'end' if $found eq 'content' and !$is_question_header;
      } else {
        # this indicates a new faq section if we found content
        $found = 'header' if !$found;
        $found = 'end' if $found eq 'content';
      }
    } elsif ($found eq 'header') {
      # faq answer if we're in a faq section
      $found = 'content' unless $found eq 'end';
    } elsif (!$found and defined $question) {
      # skip content if this isn't the faq section we're looking for
      @faq = ();
      next;
    }

    if ($found eq 'end') {
      if (defined $question) {
        # we're done
        last;
      } else {
        # add this faq section
        push @faqs, [@faq];
      }
      # start next faq section
      @faq = ();
      $found = $is_header && (!defined $question or $is_question_header) ? 'header' : '';
    }

    # faq section
    push @faq, $para;
  }

  return defined $question ? \@faq : \@faqs;
}

sub _split_perldelta ($src, $section = undef) {
  my $found = '';
  my ($started, @section, @sections);

  foreach my $para (split /\n\n+/, $src) {
    my ($is_header, $is_section_header);
    $is_header = 1 if $para =~ m/^=head\d/;

    $started = 1 if !$started and $is_header and $para !~ m/^=head1\s+(NAME|DESCRIPTION)$/;
    next unless $started;

    if ($is_header) {
      if (defined $section) {
        my $heading = _pod_to_text_content("=pod\n\n$para");
        # see if this is the start or end of the section we want
        $is_section_header = 1 if $heading eq $section;
        $found = 'header' if !$found and $is_section_header;
        $found = 'end' if $found eq 'content' and !$is_section_header;
      } else {
        # this indicates a new section if we found content
        $found = 'header' if !$found;
        $found = 'end' if $found eq 'content';
      }
    } elsif ($found eq 'header') {
      # section content if we're in a section
      $found = 'content' unless $found eq 'end';
    } elsif (!$found and defined $section) {
      # skip content if this isn't the section we're looking for
      @section = ();
      next;
    }

    if ($found eq 'end') {
      if (defined $section) {
        # we're done
        last;
      } else {
        # add this section if it has content
        push @sections, [@section] if @section > 1;
      }
      # start next section
      @section = ();
      $found = $is_header && (!defined $section or $is_section_header) ? 'header' : '';
    }

    last if $para =~ m/^=head1\s+Reporting Bugs$/;

    # section content
    push @section, $para;
  }

  return defined $section ? \@section : \@sections;
}

sub _pod_to_html ($pod, $url_perl_version = '', $with_errata = 1) {
  my $parser = MetaCPAN::Pod::XHTML->new;
  $parser->perldoc_url_prefix($url_perl_version ? "/$url_perl_version/" : '/');
  $parser->$_('') for qw(html_header html_footer);
  $parser->anchor_items(1);
  $parser->no_errata_section(1) unless $with_errata;
  $parser->output_string(\(my $output));
  $parser->parse_string_document("$pod");
  return $output;
}

sub _pod_to_text_content ($pod) {
  my $parser = Pod::Simple::TextContent->new;
  $parser->no_errata_section(1);
  $parser->output_string(\(my $output));
  $parser->parse_string_document("$pod");
  return trim($output);
}

my %escapes = ('<' => 'lt', '>' => 'gt', '|' => 'verbar', '/' => 'sol', '"' => 'quot');
sub _escape_pod ($text) {
  return $text =~ s/([<>|\/])/E<$escapes{$1}>/gr;
}

sub _append_url_path ($url, $segment) {
  $url = Mojo::URL->new($url) unless ref $url;
  push @{$url->path->parts}, $segment;
  $url->path->trailing_slash(0);
  return $url;
}

1;
