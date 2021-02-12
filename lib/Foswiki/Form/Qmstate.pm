# Plugin for Foswiki - The Free and Open Source Wiki, https://foswiki.org/
#
# QMPlugin is Copyright (C) 2019-2021 Michael Daum http://michaeldaumconsulting.com
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
  my $this = shift;

  my $id = $this->{default};
  my $net = $this->getNet;
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
  my $this = shift;

  $this->getValueMap();
  return $this->getEditOptions($this->{_value}) if defined $this->{_value};
  return $this->getDisplayOptions();
}

sub getValueMap {
  my $this = shift;

  unless (defined $this->{valueMap}) {
    my $net = $this->getNet;
    if ($net) {
      foreach my $node ($net->getNodes()) {
        $this->{valueMap}{$node->prop("id")} = $this->getState->expandValue($node->prop("title"));
      }
    }
  }

  return $this->{valueMap};
}

sub getDisplayOptions {
  my $this = shift;

  unless (defined $this->{_displayOptions}) {
    $this->{_displayOptions} = []; 

    my $net = $this->getNet;
    if ($net) {
      @{$this->{_displayOptions}} = map {$_->prop("id")} $net->getSortedNodes();
    }
  }

  return $this->{_displayOptions};
}

sub getEditOptions {
  my ($this, $value) = @_;

  $value = $this->getDefaultValue() unless defined $value && $value ne "";

  unless (defined $this->{_editOptions}) {
    my @nodes = ();

    my $net = $this->getNet;
    if ($net) {
      my $node = $net->getNode($value);

      if ($node) {
        push @nodes, $node;

        my $user = $this->getCore->getSelf();

        foreach my $edge ($node->getOutgoingEdges) {
          next unless $edge->isEnabled($user);

          push @nodes, $net->getNode($edge->prop("to"));
        }
      }
    }
    @{$this->{_editOptions}} = map {$_->prop("id")} sort {$a->index <=> $b->index} @nodes;
  }

  return $this->{_editOptions};
}

sub getCore {
  my $this = shift;

  return Foswiki::Plugins::QMPlugin::getCore();
}

sub getState {
  my ($this, $web, $topic) = @_;

  my $session = $Foswiki::Plugins::SESSION;
  $web //= $session->{webName};
  $topic //= $session->{topicName};

  my $state = $this->getCore->getState($web, $topic);

  my $workflow = $this->param("workflow");
  $state->setWorkflow($workflow) if $workflow;

  return $state;
}

sub getNet {
  my $this = shift;

  $this->{_net} //= $this->getState->getNet();

  unless (defined $this->{_net}) {
    my $session = $Foswiki::Plugins::SESSION;
    my $web = $session->{webName};
    my $topic = $session->{topicName};
    my $workflow = $this->param("workflow");

    ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $workflow || $topic);

    $this->{_net} = Foswiki::Plugins::QMPlugin::Net->new($web, $topic);
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
  my ($this, $format, $value, $attrs) = @_;

  my $displayValue = $this->getDisplayValue($value);
  $format =~ s/\$value\(display\)/$displayValue/g;
  $format =~ s/\$value/$value/g;

  return $this->SUPER::renderForDisplay($format, $value, $attrs);
}

sub getDisplayValue {
  my ($this, $value) = @_;

  return $value unless $this->isValueMapped();

  $this->getValueMap();
  $this->getDisplayOptions();
  my @vals = ();
  foreach my $val (split(/\s*,\s*/, $value)) {
    if (defined($this->{valueMap}{$val})) {
      push @vals, $this->{valueMap}{$val};
    } else {
      push @vals, $val;
    }
  }
  return join(", ", @vals);
}

sub renderForEdit {
  my ($this, $meta, $value) = @_;

  $this->getValueMap();
  unless (defined $this->{valueMap}{$value}) {
    print STDERR "WARNING: qmstate '$value' not defined in workflow, falling back to default value\n";
    $value = $this->getDefaultValue;
  }

  $this->{_value} = $value;

  my ($extra, $html) = $this->SUPER::renderForEdit($meta, $value);
  undef $this->{_value};

  # add current value hidden in case the state will not change
  $html .= CGI::hidden(-name => $this->{name}, -default => $value);

  return ($extra, $html);
}

sub _encode {
  my $text = shift;

  $text = Encode::encode_utf8($text) if $Foswiki::UNICODE;
  $text =~ s/([^0-9a-zA-Z-_.:~!*\/])/'%'.sprintf('%02x',ord($1))/ge;

  return $text;
}

1;
