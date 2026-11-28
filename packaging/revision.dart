// Native packages start at -1; Gentoo omits the initial -r0.
const packageRevision = 2;
const gentooRevision = 'r1';

String kernelRelease(String version, String flavor) =>
    '$version-$gentooRevision-eku-$flavor';
