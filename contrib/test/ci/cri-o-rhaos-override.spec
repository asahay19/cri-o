# RHAOS-compatible cri-o override RPM for rpm-ostree replace on OpenShift nodes.
#
# Unlike contrib/test/ci/cri-o.spec (CI testing), this package ships ONLY the
# crio and pinns binaries. It does not replace /etc/crio/crio.conf, systemd
# units, or CNI configs managed by MachineConfig on OCP nodes.
#
# Build with: hack/build-rhaos-override-rpm.sh

%global debug_package %{nil}

%global provider github
%global provider_tld com
%global project cri-o
%global repo cri-o
%global provider_prefix %{provider}.%{provider_tld}/%{project}/%{repo}
%global import_path %{provider_prefix}
%global git0 https://%{import_path}
%global service_name crio

Name: %{repo}
Version: 1.33.12
Release: 1.dedup%{?dist}
Summary: Kubernetes Container Runtime Interface for OCI-based containers (dedup override)
License: ASL 2.0
URL: %{git0}
Source0: %{name}-test.tar.gz

BuildRequires: make
BuildRequires: git
BuildRequires: glib2-devel
BuildRequires: glibc-static
BuildRequires: gpgme-devel
BuildRequires: libassuan-devel
BuildRequires: libseccomp-devel
BuildRequires: libselinux-devel
BuildRequires: openssl-devel
BuildRequires: pkgconfig(systemd)

Requires(pre): container-selinux
Requires: containers-common >= 1:0.1.24-3
Requires: runc > 1.0.0-57
Requires: containernetworking-plugins >= 0.7.5-1
Requires: conmon
Obsoletes: ocid <= 0.3
Provides: ocid = %{version}-%{release}
Provides: %{service_name} = %{version}-%{release}

%description
Binary-only cri-o override for OpenShift rpm-ostree testing. Includes storage
deduplication support (crio dedup, enable_storage_dedup). Does not replace
node configuration files.

%prep
%setup -qn %{name}-test
sed -i 's/install.config: crio.conf/install.config:/' Makefile
sed -i 's/install.bin: binaries/install.bin:/' Makefile
sed -i 's/\.gopathok//' Makefile
sed -i 's/go test/$(GO) test/' Makefile
sed -i 's/%{version}/%{version}-%{release}/' internal/version/version.go

%build
mkdir _output
pushd _output
mkdir -p src/%{provider}.%{provider_tld}/{%{project},opencontainers}
ln -s $(dirs +1 -l) src/%{import_path}
popd

ln -s vendor src
export GOPATH=$(pwd)/_output:$(pwd)
export GO111MODULE=off
export BUILDTAGS="libtrust_openssl containers_image_ostree_stub \
$(hack/seccomp_tag.sh) \
$(hack/selinux_tag.sh) \
$(hack/openpgp_tag.sh) \
$(hack/libsubid_tag.sh)"
make bin/crio bin/pinns

%install
install -D -m 0755 bin/%{service_name} %{buildroot}%{_bindir}/%{service_name}
install -D -m 0755 bin/pinns %{buildroot}%{_bindir}/pinns

%files
%{_bindir}/%{service_name}
%{_bindir}/pinns

%changelog
* Mon Jun 30 2026 Dedup override build
- Binary-only RHAOS override RPM for OCPNODE-4588
