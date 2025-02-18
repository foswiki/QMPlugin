# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2019-2025 Michael Daum http://michaeldaumconsulting.com
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details, published at
# http://www.gnu.org/copyleft/gpl.html

package Foswiki::Form::Qmstate;

use strict;
use warnings;

use CGI ();
use Foswiki::Func();
use Foswiki::Form::Radio ();
use Foswiki::Plugins::QMPlugin ();
use Foswiki::Plugins::QMPlugin::Net ();

our @ISA = ('Foswiki::Form::Radio');

BEGIN {
  if ($Foswiki::cfg{UseLocale}) {
    require locale;
    import locale();
  }
}

sub finish {
  my $this = shift;

  $this->SUPER::finish();

  undef $this->{_params};
  undef $this->{_displayOptions};
  undef $this->{_editOptions};
  undef $this->{_net}; # don't need to finish the nets themselves, this is done in the plugin
  undef $this->{_value};
}

sub isMultiValued { return 0; }
sub isValueMapped { return 1; }

sub getDefaultValue {
  my ($this, $web, $topic) = @_;

  my $id = $this->{default} // '';
  my $net = $this->getNet($web, $topic);
  return $id unless defined $net;

  my $node = $id?$net->getNode($id):$net->getDefaultNode;
  return "" unless defined $node;

  return $node->prop("id");
}

sub param {
  my ($this, $key) = @_;

  unless (defined $this->{_params}) {
    my %params = Foswiki::Func::extractParameters($this->{value});
    $this->{_params} = \%params;
  }

  return (defined $key) ? $this->{_params}{$key} : $this->{_params};
}

sub getOptions {
  my ($this, $web, $topic) = @_;

  $this->getValueMap($web, $topic);
  return $this->getEditOptions($this->{_value}, $web, $topic) if defined $this->{_value};
  return $this->getDisplayOptions($web, $topic);
}

sub getValueMap {
  my ($this, $web, $topic) = @_;

  unless (defined $this->{valueMap}) { # SMELL: valueMap is different per web.topic
    my $state = $this->getState($web, $topic);
    return unless $state;
    my $net = $state->getNet($web, $topic);

    if ($net) {
      foreach my $node ($net->getNodes()) {

        my $id = $node->prop("id");
        my $title = $state->expandValue($node->prop("title"));
        my $message = $state->expandValue($node->prop("message"));

        $this->{valueMap}{$id} = $title;
        $this->{_descriptions}{$id} = $message;
      }
    }
  }

  return $this->{valueMap};
}

sub getDisplayOptions {
  my ($this, $web, $topic) = @_;

  unless (defined $this->{_displayOptions}) {
    $this->{_displayOptions} = []; 

    my $net = $this->getNet($web, $topic);
    if ($net) {
      @{$this->{_displayOptions}} = map {$_->prop("id")} $net->getSortedNodes();
    }
  }

  return $this->{_displayOptions};
}

sub getEditOptions {
  my ($this, $value, $web, $topic) = @_;

  $value = $this->getDefaultValue($web, $topic) unless defined $value && $value ne "";

  unless (defined $this->{_editOptions}) {
    my @nodes = ();

    my $net = $this->getNet($web, $topic);
    if ($net) {
      my $node = $net->getNode($value);


      my %seen = ();
      if ($node) {
        push @nodes, $node;
        $seen{$node->prop("id")} = 1;

        my $user = $this->getCore->getSelf();

        foreach my $edge ($node->getOutgoingEdges) {
          next if $edge->prop("action") eq "_hidden_";
          next unless $edge->isEnabled($user);

          my $toNode = $net->getNode($edge->prop("to"));
          next if $seen{$toNode->prop("id")};

          $seen{$toNode->prop("id")} = 1;
          push @nodes, $toNode;
        }
      }
    }
    @{$this->{_editOptions}} = map {$_->prop("id")} sort {$a->{_index} <=> $b->{_index}} @nodes;
  }

  return $this->{_editOptions};
}

sub getCore {
  my $this = shift;

  return Foswiki::Plugins::QMPlugin::getCore();
}

#use Carp qw(cluck);
sub getState {
  my ($this, $web, $topic) = @_;

  # SMELL: the current formfield isn't necessarily part of the base topic
  my $session = $Foswiki::Plugins::SESSION;

  #cluck("called getState without web.topic") unless defined $web && defined $topic;

  $web //= $session->{webName};
  $topic //= $session->{topicName};


  my $state = $this->getCore->getState($web, $topic);

  return unless $state;
  my $workflow = $this->param("workflow");
  $state->setWorkflow($workflow) if $workflow;

  return $state;
}

sub getNet {
  my ($this, $web, $topic) = @_;

  unless (defined $this->{_net}) {
    my $session = $Foswiki::Plugins::SESSION;
    $web //= $session->{webName};
    $topic //= $session->{topicName};
    my $workflow = $this->param("workflow");

    ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $workflow || $topic);

    $this->{_net} = $this->getCore->getNet($web, $topic);
  }

  return $this->{_net};
}

sub cssClasses {
  my $this = shift;
  if ($this->isMandatory()) {
    push(@_, 'foswikiMandatory');
  }

  push @_, 'foswikiStateField';

  return join(' ', @_);
}

sub renderForDisplay {
  my ($this, $format, $value, $attrs, $meta) = @_;

  my $web = $meta ? $meta->web : undef;
  my $topic = $meta ? $meta->topic : undef;

  my $displayValue = $this->getDisplayValue($value, $web, $topic);
  $format =~ s/\$value\(display\)/$displayValue/g;
  $format =~ s/\$value/$value/g;

  return $this->SUPER::renderForDisplay($format, $value, $attrs);
}

sub getDisplayValue {
  my ($this, $value, $web, $topic) = @_;

  my $state = $this->getState($web, $topic);
  return $value unless $state;
  return $state->translate($value) unless $this->isValueMapped();

  $this->getValueMap($web, $topic);
  $this->getDisplayOptions($web, $topic);
  my @vals = ();
  foreach my $val (split(/\s*,\s*/, $value)) {
    if (defined($this->{valueMap}{$val})) {
      push @vals, $state->translate($this->{valueMap}{$val});
    } else {
      push @vals, $state->translate($val);
    }
  }

  return join(", ", @vals);
}

sub renderForEdit {
  my ($this, $meta, $value) = @_;

  my $web = $meta->web;
  my $topic = $meta->topic;

  Foswiki::Func::pushTopicContext($web, $topic);

  $this->{_editOptions} = undef;
  $this->{_displayOptions} = undef;
  $this->{_net} = undef;

  $this->getValueMap($web, $topic);
  unless (defined $value && defined $this->{valueMap}{$value}) {
    print STDERR "WARNING: qmstate '$value' not defined in workflow, falling back to default value\n";
    $value = $this->getDefaultValue($web, $topic);
  }
  $this->{_value} = $value;

  my $format = '<div><label title="$description" class="jqUITooltip" data-theme="$theme" data-arrow="true" data-track="false" data-position="$tooltipPosition" data-delay="250"><input type="radio" name="$name" value="$value" class="$class" $selected />$label</label></div>';
  my @result = ();
  my $state = $this->getState($web, $topic);
  return $this->SUPER::renderForEdit($meta, $value) unless $state;

  foreach my $item ( @{ $this->getOptions($web, $topic) } ) {
      my $line = $format;

      my $selected = ($item eq $value ? 'checked="checked"' : '');
      my $label = $state->translate($this->{valueMap}{$item} // $item);
      my $description = $this->{_descriptions}{$item} // '';
      $description = $state->expandValue($description) if $description =~ /%/;

      $line =~ s/\$value\b/$item/g;
      $line =~ s/\$description\b/$description/g;
      $line =~ s/\$label\b/$label/g;
      $line =~ s/\$selected\b/$selected/g;

      push @result, $line;
  }
  push @result, "<input type='hidden' name='$this->{name}' value='$value' />";
  my $html = "<div class='foswikiRadioButtonGroup' style='display:inline-block;column-count:$this->{size}'>" . join("\n", @result) . "</div>";

  my $class = $this->cssClasses("foswikiRadioButton");
  my $theme = $this->param("theme") // "info";
  my $tooltipPosition = $this->param("tooltipPosition") // "left";

  $html =~ s/\$class\b/$class/g;
  $html =~ s/\$name\b/$this->{name}/g;
  $html =~ s/\$theme\b/$theme/g;
  $html =~ s/\$tooltipPosition\b/$tooltipPosition/g;

  undef $this->{_value};

  Foswiki::Func::popTopicContext();
  return ('', $html);
}

sub _encode {
  my $text = shift;

  $text = Encode::encode_utf8($text) if $Foswiki::UNICODE;
  $text =~ s/([^0-9a-zA-Z-_.:~!*\/])/'%'.sprintf('%02x',ord($1))/ge;

  return $text;
}

1;
