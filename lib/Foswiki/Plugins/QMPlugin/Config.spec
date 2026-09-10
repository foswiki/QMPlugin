# ---+ Extensions
# ---++ QMPlugin

# **PERL LABEL="REST Configuration" CHECK="undefok emptyok"**
# configure external REST handlers that can be integrated into workflow transitions
$Foswiki::cfg{QMPlugin}{RestConfig} = {
  some_id => {
    url => "https://foo.bar",
    method => "POST",
    body => {
      key1 => "%val%",
      key2 => "%val%"
    }
  }
};

1;
