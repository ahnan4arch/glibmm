#!/usr/bin/env perl

## Copyright 2011 Krzesimir Nowak
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with this program; if not, write to the Free Software
## Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
##

use strict;
use warnings;

use File::Spec;
use Getopt::Long;
use IO::File;
use XML::Parser::Expat;

my $glob_magic_toplevel = 'top-level';
my $glob_header =
'## This file was generated by taghandlerwriter.pl script.
##
## Copyright 2011 Krzesimir Nowak
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 2 of the License, or
## (at your option) any later version.
##
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.
##
## You should have received a copy of the GNU General Public License
## along with this program; if not, write to the Free Software
## Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307, USA.
##';

sub nl
{
  return (shift or '') . "\n";
}

sub setup_ignores($)
{
  my $filename = shift;
  my $fd = IO::File->new ($filename, 'r');

  unless (defined ($fd))
  {
    return ();
  }

  my @lines = $fd->getlines ();
  my %omit = ();

  $fd->close ();
  foreach my $line (@lines)
  {
    $line =~ s/\s*#.*//g;
    $line =~ s/^\s+//g;
    $line =~ s/\s+$//g;
    if ($line)
    {
      $omit{$line} = 0;
    }
  }
  return %omit;
}

sub handle_tree ($$$)
{
  my ($expat, $tree, $tag) = @_;
  my @context = ($glob_magic_toplevel, $expat->context);
  my $root = $tree;

  foreach my $elem (@context)
  {
    unless (exists ($root->{$elem}))
    {
      $root->{$elem} = {};
    }

    my $href = $root->{$elem};

    $root = $href;
  }
  unless (exists ($root->{$tag}))
  {
    $root->{$tag} = {};
  }
}

sub handle_attributes ($$$@)
{
  my ($expat, $tags, $tag, @atts_vals) = @_;

  unless (exists ($tags->{$tag}))
  {
    $tags->{$tag} = {'count' => 0, 'attributes' => {}};
  }

  my $elem = $tags->{$tag};
  my $atts = $elem->{'attributes'};
  my $att = undef;

  ++$elem->{'count'};
  foreach my $entry (@atts_vals)
  {
    unless (defined ($att))
    {
      $att = $entry;
    }
    else
    {
      if (exists ($atts->{$att}))
      {
        my $attribute = $atts->{$att};

        ++$attribute->{'count'};

        if (defined ($attribute->{'value'}) and $attribute->{'value'} ne $entry)
        {
          $attribute->{'value'} = undef;
        }
      }
      else
      {
        $atts->{$att} = {'count' => 1, 'value' => $entry};
      }
      $att = undef;
    }
  }
}

sub add_file_to_list($$)
{
  my ($file, $list) = @_;

  if ($file =~ /\.gir$/)
  {
    push (@{$list}, $file);
  }
  else
  {
    print STDERR nl ('Not a gir file: ' . $list . '.');
  }
}

sub get_attributes_of_tag ($$)
{
  my ($tagname, $tags) = @_;
  my @attributes = ();
  my $tag = $tags->{$tagname};
  my $atts = $tag->{'attributes'};
  my $total_count = $tag->{'count'};

  while (my ($attribute, $desc) = each %{$atts})
  {
    my $mandatory = (($total_count == $desc->{'count'}) ? 1 : 0);
    my $single_value = $desc->{'value'};
    my $new_desc =
    {
      'name' => $attribute,
      'mandatory' => $mandatory,
      'single_value' => $single_value
    };

    push (@attributes, $new_desc);
  }

  @attributes = sort { $a->{'name'} cmp $b->{'name'} } @attributes;

  return \@attributes;
}

sub get_kids_of_tag ($$)
{
  my ($tag, $tree) = @_;
  my @kids = ();
  my @tags_queue = map { [$_, $tree] } sort keys %{$tree};

  for my $pair (@tags_queue)
  {
    my $subtree_tag = $pair->[0];
    my $subtree = $pair->[1];
    my $kid = $subtree->{$subtree_tag};
    my @kid_tags = sort keys %{$kid};

    if ($subtree_tag eq $tag)
    {
      push (@kids, @kid_tags);
    }

    push (@tags_queue, map { [$_, $kid] } @kid_tags);
  }

  my %unique_kids = ();

  foreach my $kid (@kids)
  {
    $unique_kids{$kid} = undef;
  }

  @kids = sort keys %unique_kids;

  return \@kids;
}

sub merge_tree_and_tags ($$)
{
  my ($tree, $tags) = @_;
  my %merge = ();

  foreach my $tag (sort (keys %{$tags}, $glob_magic_toplevel))
  {
    $merge{$tag} =
    {
      'attributes' => get_attributes_of_tag ($tag, $tags),
      'kids' => get_kids_of_tag ($tag, $tree)
    };
  }

  return \%merge;
}

sub func_from_tag ($)
{
  my $tag = shift;
  my $func_tag = lc ($tag);

  $func_tag =~ s/\W+/_/g;

  return $func_tag;
}

sub write_tag_handlers ($$$)
{
  my ($merge, $output_dir, $package_prefix) = @_;
  my $pm = 'Tags';
  my $tags_handlers_name = File::Spec->catfile ($output_dir, 'Common', $pm . '.pm');
  my $tags_handlers_fd = IO::File->new ($tags_handlers_name, 'w');

  unless (defined ($tags_handlers_fd))
  {
    print STDERR nl ('Failed to open ' . $tags_handlers_name . ' for writing.');
    exit 1;
  }

  print STDOUT nl ('Writing ' . $tags_handlers_name . '.');

  my $package_name = $package_prefix . '::Common::' . $pm;
  my $contents = nl ($glob_header) .
                 nl () .
                 nl ('package ' . $package_name . ';') .
                 nl () .
                 nl ('use strict;') .
                 nl ('use warnings;') .
                 nl () .
                 nl ('use Gir::Handlers::Generated::Common::Misc;') .
                 nl ();
  my @handlers = ();

  while (my ($tag, $desc) = each (%{$merge}))
  {
    if ($tag eq $glob_magic_toplevel)
    {
      next;
    }

    my $attributes = $desc->{'attributes'};
    my @mandatory_atts = ();
    my @optional_atts = ();

    foreach my $att (@{$attributes})
    {
      my $att_name = $att->{'name'};

      if ($att->{'mandatory'})
      {
        push (@mandatory_atts, $att_name);
      }
      else
      {
        my $single_value = $att->{'single_value'};

        if (defined ($single_value))
        {
          if ($single_value eq '0')
          {
            $single_value = '1';
          }
          elsif ($single_value eq '1')
          {
            $single_value = '0';
          }
          else
          {
            $single_value = 'undef';
          }
        }
        else
        {
          $single_value = 'undef';
        }
        push (@optional_atts, [$att_name, $single_value]);
      }
    }

    my $handler .= nl ('sub get_' . func_from_tag ($tag) . '_params (@)') .
                   nl ('{') .
                   nl ('  return Gir::Handlers::Generated::Common::Misc::extract_values') .
                   nl ('  (') .
                   nl ('    [');

    {
      my @att_lines = ();

      foreach my $att (@mandatory_atts)
      {
        push (@att_lines, '      \'' . $att . '\'');
      }
      $handler .= nl (join (nl (','), @att_lines)) .
                  nl ('    ],') .
                  nl ('    [');
      @att_lines = ();

      foreach my $att (@optional_atts)
      {
        push (@att_lines, '      [\'' . $att->[0] . '\', ' . $att->[1] . ']');
      }
      $handler .= nl (join (nl (','), @att_lines)) .
                  nl ('    ],') .
                  nl ('    \\@_') .
                  nl ('  );') .
                  nl ('}') .
                  nl ();
      push (@handlers, $handler);
    }
  }

  $contents .= nl (join (nl (), sort (@handlers))) .
               nl ('1; # indicate proper module load.');
  $tags_handlers_fd->print ($contents);
  $tags_handlers_fd->close ();
}

sub module_from_tag ($)
{
  # unreadable, huh?
  # - splits 'foo-BAR:bAz' to 'foo', 'BAR' and 'bAz'
  # - changes 'foo' to 'Foo', 'BAR' to 'Bar' and 'bAz' to 'Baz'
  # - joins 'Foo', 'Bar' and 'Baz' into one string 'FooBarBaz'
  # - returns the joined string
  return join ('', map { ucfirst lc } split (/\W+/, shift));
}

sub write_tag_modules ($$$)
{
  my ($merge, $output_dir, $package_prefix) = @_;

  foreach my $tag (sort keys %{$merge})
  {
    my $pm = module_from_tag ($tag);
    my $tags_module_name = File::Spec->catfile ($output_dir, $pm . '.pm');
    my $tags_module_fd = IO::File->new ($tags_module_name, 'w');

    unless (defined ($tags_module_fd))
    {
      print STDERR nl ('Failed to open ' . $tags_module_name . ' for writing.');
      exit 1;
    }

    print STDOUT nl ('Writing ' . $tags_module_name . '.');

    my $kids = $merge->{$tag}{'kids'};
    my $package_name = $package_prefix . '::' . $pm;
    my @uses = ();
    my @default_start_impls = ();
    my @default_end_impls = ();
    my @start_bodies = ();
    my @end_bodies = ();
    my @start_store = ();
    my @end_store = ();
    my @subhandlers = ();

    foreach my $kid (@{$kids})
    {
      my $kid_module = $package_prefix . '::' . module_from_tag ($kid);
      my $kid_func = func_from_tag ($kid);
      my $kid_start = '_' . $kid_func . '_start';
      my $kid_start_impl = $kid_start . '_impl';
      my $kid_end = '_' . $kid_func . '_end';
      my $kid_end_impl = $kid_end . '_impl';
      my $use = 'use ' . $kid_module . ';';
      my $start_impl = nl ('sub ' . $kid_start_impl . ' ($$$)') .
                       nl ('{') .
                       nl ('  my $self = shift;') .
                       nl () .
                       nl ('  unless ($self->_is_start_ignored (\'' . $kid . '\'))') .
                       nl ('  {') .
                       nl ('    #TODO: throw something.') .
                       nl ('    print STDERR \'' . $package_name . '::' . $kid_start_impl . ' not implemented.\' . "\\n";') .
                       nl ('    exit (1);') .
                       nl ('  }') .
                       nl ('}');
      my $end_impl = nl ('sub ' . $kid_end_impl . ' ($$)') .
                     nl ('{') .
                     nl ('  my $self = shift;') .
                     nl () .
                     nl ('  unless ($self->_is_end_ignored (\'' . $kid . '\'))') .
                     nl ('  {') .
                     nl ('    #TODO: throw something.') .
                     nl ('    print STDERR \'' . $package_name . '::' . $kid_end_impl . ' not implemented.\' . "\\n";') .
                     nl ('    exit (1);') .
                     nl ('  }') .
                     nl ('}');
      my $start_body = nl ('sub ' . $kid_start . ' ($$@)') .
                       nl ('{') .
                       nl ('  my ($self, $parser, @atts_vals) = @_;') .
                       nl ('  my $params = ' . $package_prefix . '::Common::Tags::get_' . $kid_func . '_params (@atts_vals);') .
                       nl () .
                       nl ('  $self->' . $kid_start_impl . ' ($parser, $params);') .
                       nl ('}');
      my $end_body = nl ('sub ' . $kid_end . ' ($$)') .
                     nl ('{') .
                     nl ('  my ($self, $parser) = @_;') .
                     nl () .
                     nl ('  $self->' . $kid_end_impl . ' ($parser);') .
                     nl ('}');
      my $start_store_member = '      \'' . $kid . '\' => \\&' . $kid_start;
      my $end_store_member = '      \'' . $kid . '\' => \\&' . $kid_end;
      my $subhandler = '      \'' . $kid . '\'';

      push (@uses, $use);
      push (@default_start_impls, $start_impl);
      push (@default_end_impls, $end_impl);
      push (@start_bodies, $start_body);
      push (@end_bodies, $end_body);
      push (@start_store, $start_store_member);
      push (@end_store, $end_store_member);
      push (@subhandlers, $subhandler);
    }

    my $contents = nl ($glob_header) .
                   nl () .
                   nl ('package ' . $package_name . ';') .
                   nl () .
                   nl ('use strict;') .
                   nl ('use warnings;') .
                   nl () .
                   nl ('use parent qw(Gir::Handlers::Generated::Common::Base);') .
                   nl () .
                   nl ('use Gir::Handlers::Generated::Common::Store;') .
                   nl ('use Gir::Handlers::Generated::Common::Tags;') .
                   nl (join (nl (), @uses)) .
                   nl () .
                   nl ('##') .
                   nl ('## private virtuals') .
                   nl ('##') .
                   nl (join (nl (), @default_start_impls)) .
                   nl (join (nl (), @default_end_impls)) .
                   nl ('sub _setup_handlers ($)') .
                   nl ('{') .
                   nl ('  my $self = shift;') .
                   nl () .
                   nl ('  $self->_set_handlers') .
                   nl ('  (') .
                   nl ('    Gir::Handlers::Generated::Common::Store->new') .
                   nl ('    ({') .
                   nl (join (nl (','), @start_store)) .
                   nl ('    }),') .
                   nl ('    Gir::Handlers::Generated::Common::Store->new') .
                   nl ('    ({') .
                   nl (join (nl (','), @end_store)) .
                   nl ('    })') .
                   nl ('  );') .
                   nl ('}') .
                   nl () .
                   nl ('sub _setup_subhandlers ($)') .
                   nl ('{') .
                   nl ('  my $self = shift;') .
                   nl () .
                   nl ('  $self->_set_subhandlers') .
                   nl ('  (') .
                   nl ('    $self->_generate_subhandlers') .
                   nl ('    ([') .
                   nl (join (nl (','), @subhandlers)) .
                   nl ('    ])') .
                   nl ('  );') .
                   nl ('}') .
                   nl () .
                   nl ('##') .
                   nl ('## private (sort of)') .
                   nl ('##') .
                   nl (join (nl (), @start_bodies)) .
                   nl (join (nl (), @end_bodies)) .
                   nl ('##') .
                   nl ('## public') .
                   nl ('##') .
                   nl ('sub new ($)') .
                   nl ('{') .
                   nl ('  my $type = shift;') .
                   nl ('  my $class = (ref ($type) or $type or \'' . $package_name . '\');') .
                   nl ('  my $self = $class->SUPER::new ();') .
                   nl () .
                   nl ('  return bless ($self, $class);') .
                   nl ('}') .
                   nl () .
                   nl ('1; # indicate proper module load.');
    $tags_module_fd->print ($contents);
    $tags_module_fd->close ();
  }
}

sub main()
{
  my $ignore_file = undef;
  my $output_dir = undef;
  my $package_prefix = undef; # Gir::Handlers::Generated::Tags
  my @files_to_parse = ();
  my $opt_parse_result = GetOptions ('ignore-file|i=s' => \$ignore_file,
                                     'output-dir|d=s' => \$output_dir,
                                     'package-prefix|p=s' => \$package_prefix,
                                     '<>' => sub { add_file_to_list ($_[0], \@files_to_parse); }
                                    );

  if (not $opt_parse_result or not @files_to_parse or not $output_dir or not $package_prefix)
  {
    print STDERR nl ('taghandlerwriter.pl PARAMS FILES.') .
                 nl ('PARAMS:') .
                 nl ('  --output-dir=<name> | -o <name> - output directory') .
                 nl ('  --package-prefix=<prefix> | -p <prefix> - prefix for package names') .
                 nl ('  [--ignore-file=<filename> | -i <filename> - name of file containing a list of girs to ignore]') .
                 nl ('FILES: gir files.');
    exit 1;
  }

  my %omit_files = ();

  if (defined ($ignore_file))
  {
    %omit_files = setup_ignores ($ignore_file);
  }

  my @used_files = ();
  my @omitted_files = ();
  # $tag =>
  # {
  #   'attributes' =>
  #   {
  #     $attribute =>
  #     {
  #       'count' => $count,
  #       'value' => $value
  #     }
  #   }
  #   'count' => $count
  # }
  my $tags = {};
  # $tag =>
  # {
  #   $kid1 =>
  #   {
  #     $grandkid1 => ...
  #     $grandkid2 => ...
  #     ...
  #   }
  #   $kid2 =>
  #   {
  #     $grandkid1 => ...
  #     $grandkid2 => ...
  #     ...
  #   }
  #   ...
  # }
  my $tree = {};

  for my $file (@files_to_parse)
  {
    my (undef, undef, $basename) = File::Spec->splitpath ($file);

    if (exists $omit_files{$basename})
    {
      print STDOUT nl ('Ignoring ' . $basename .'.');
      push (@omitted_files, $basename);
    }
    else
    {
      print STDOUT nl ('Parsing ' . $basename . '.');
      push (@used_files, $basename);

      my $parser = XML::Parser::Expat->new ();

      $parser->setHandlers
      (
        'Start' => sub {handle_attributes ($_[0], $tags, $_[1], @_[2 .. @_ - 1]); handle_tree ($_[0], $tree, $_[1])}
      );
      $parser->parsefile ($file);
      $parser->release ();
    }
  }

  # $tag =>
  # {
  #   'attributes' => [{'name' => attr1, 'mandatory' => 0/1, 'single_value' => ?/undef}, ...],
  #   'kids' => [tag1, ...]
  # }
  my $merge = merge_tree_and_tags ($tree, $tags);

  $tags = undef;
  $tree = undef;
  write_tag_handlers ($merge, $output_dir, $package_prefix);
  write_tag_modules ($merge, $output_dir, $package_prefix);

  exit 0;
}

#run!
main();
