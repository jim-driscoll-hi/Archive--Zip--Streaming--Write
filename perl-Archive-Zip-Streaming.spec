Name: perl-Archive-Zip-Streaming
Version: 0.1.0
Release: 1
License: BSD
Summary: Common libraries with unrestricted internal distribution
Group: Development/Libraries
Packager: Jim Driscoll <jim.driscoll@heartinternet.co.uk>
Source: Archive-Zip-Streaming-%{version}.tar
BuildArch: noarch
BuildRoot: %{_builddir}/%{name}-%{version}-%{release}

%description
Perl libraries to support streaming to and from zip files.

%prep
%setup -n Archive-Zip-Streaming-%{version}

%build

%install
install -d $RPM_BUILD_ROOT/%{perl_vendorlib}/Archive/Zip/Streaming
install Archive/Zip/Streaming/*.pm $RPM_BUILD_ROOT/%{perl_vendorlib}/Archive/Zip/Streaming/

%files
%defattr(-,root,root)
%{perl_vendorlib}/Archive/Zip/Streaming

%changelog
* Thu Apr 17 2014 Jim Driscoll <jim.driscoll@heartinternet.co.uk> 0.1.0-1
- Initial RPM

