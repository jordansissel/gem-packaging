#!/bin/sh

if [ "$#" -eq 0 ] ; then
  echo "Usage: $0 <gem> [versioninfo]"
  echo "For example: $0 json '>1'"
  exit 1
fi

if ! gem list --local | grep -q gem2rpm ; then
  echo "You need to install gem2rpm; run 'gem install gem2rpm'"
  exit 1
fi

PROG=$0
if [ "${PROG#/}" == "$PROG" ] ; then
  PROG="$PWD/$0"
fi
   

RPM_TOPDIR="$PWD"
export RPM_TOPDIR

mkdir -p SOURCES SPECS BUILD SRPMS RPMS
gem=$1
version="${2:->= 0}"
echo "Building $gem $version"

if [ ! -z "$version" ] ; then
  gemopts="--version $version"
else
  gemopts=""
fi

set -e

# Some gems (jferris-mocha) require things to be installed before we install the gem.

gem install --quiet --no-ri --no-rdoc --install-dir $PWD/SOURCES rake

# Use 'install' to get the gems since 'gem fetch' won't grab dependencies.
if [ -z "$SOURCE" ] ; then
  gem install --quiet --no-ri --no-rdoc --install-dir $PWD/SOURCES --version "$version" "$gem"
else 
  gem install --quiet --no-ri --no-rdoc --install-dir $PWD/SOURCES --version "$version" "$gem" --source  "$SOURCE"
fi

# now remove the installation and just keep the gems.
rm -rf SOURCES/{bin,doc,gems,specifications}
mv SOURCES/cache/* SOURCES/
rmdir SOURCES/cache

for gem in SOURCES/*.gem; do

  # I will let you (the reader) decide which circle of hell parsing YAML in
  # shell belongs in... Find the gem name and version according to the spec:
  gemspec="$(gem specification $gem)"
  name=$(echo "$gemspec" | sed -ne '/^name: /{p;q}' | awk '{print $2}' | tr -d '"')
  version=$(echo "$gemspec" | sed -ne '/^  version: /{p;q}' | awk '{print $2}' | tr -d '"')
  spec="SPECS/rubygem-$name-$version.spec"

  # use '|| true' here becuase we have 'set -e' enabled and non-zero exits from
  # subshells that set variables still incurs an exit. We care about the content,
  # not the exit code.
  have=$(rpm -q -p RPMS/*/*.rpm --provides | grep -F "rubygem($name) = $version" || true)

  if [ ! -z "$have" ] ; then
    echo "Already have rpm for $name=$version. Skipping."
    continue
  fi

  echo "Building rpm for $name=$version"
  gem2rpm $gem > $spec

  # concatonate line continuations for easier substituting.
  sed -i -ne '/\\$/N; /\\$/! { s/\\\n//g; p; }' $spec

  # munge weird gem-valid version comparisons to rpm valid
  # really we should turn ~> N.Y into ' >= N.Y, < N+1.0'
  sed -i -e '/^Requires: / { s/~>/>=/ }' $spec

  sed -i -e "s/^Name: .*/&-$version/" $spec

  date=$(date +"%Y%m%d%H%M%S")
  sed -i -e "s/^Release: 1/Release: $date/" $spec

  # Hacks to handle CentOS gem builds and other oddities from gem2rpm 
  # translation should go here.
  #sed -i -e 's@^gem install.*@& --no-ri --no-rdoc@' $spec
  case $name in
    mysql) sed -i -e 's@^gem install.*@& -- --with-mysql-lib=/usr/lib64/mysql --with-mysql-include=/usr/include/mysql@' $spec ;;
    stompserver)
      sed -i -e 's@^URL: .*@URL: http://stompserver.rubyforge.org/@' $spec ;;
    gem_plugin)
      sed -i -e 's@^URL: .*@URL: http://somethingtomakerpmhappy/@' $spec ;;
    test-unit)
      sed -i -e 's@/testrb$@/testrb-rubygem@' $spec
      sed -i -e 's@^%clean.*@mv %{buildroot}/%{_bindir}/testrb %{buildroot}/%{_bindir}/testrb-rubygem\n&@' $spec
      ;;
    fastthread)
      sed -i -e 's@^URL:@URL: http://none/given@' $spec
      ;;
    passenger)
      # Disable AutoReqProv for passenger, it sometimes finds it needs 
      # /usr/bin/ruby1.8 when my ruby rpm doesn't provide that.
      sed -i -e 's@^BuildRoot.*@&\nAutoReqProv: no@' $spec
      ;;
    puppet)
      sed -i -e 's@^BuildRoot.*@&\nAutoReqProv: no@' $spec
      ;;
    json_pure)
      # both json and json_pure provide /usr/bin/edit_json.rb and prettify_json.rb
      sed -i -e '/edit_json.rb$/d; /prettify_json.rb/d' $spec
      sed -i -e '/mkdir -p %{buildroot}\/%{_bindir}/d' $spec
      sed -i -e '/mv %{buildroot}%{gemdir}\/bin\/\* %{buildroot}\/%{_bindir}/d' $spec
      sed -i -e '/rmdir %{buildroot}%{gemdir}\/bin/d' $spec
      sed -i -e '/find %{buildroot}%{geminstdir}\/bin -type f | xargs chmod a+x/d' $spec
      sed -i -e 's/%files/&\n%{gemdir}\/bin\/edit_json.rb/' $spec
      sed -i -e 's/%files/&\n%{gemdir}\/bin\/prettify_json.rb/' $spec

      #sed -i -e 's/^gem install.*/&\nrm %{buildroot}%{gemdir}\/bin/' $spec

      #sed -i -e 's/^gem install.*/&\nfind %{buildroot}%{_bindir} -name "edit_json.rb" -delete -o -name "prettify_json.rb" -delete/' $spec
      ;;
    #buildr)
      #sed -i -e 's/Requires: rubygem(rspec) = 1.2.8/Requires: rubygem(rspec) >= 1.2.8/' $spec
      #;;


  esac

  rpmbuild -bb $spec --buildroot $PWD/BUILD-$package --define "_topdir $PWD" $spec
done
