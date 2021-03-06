{***************************************************************************}
{                                                                           }
{           Delphi Package Manager - DPM                                    }
{                                                                           }
{           Copyright � 2019 Vincent Parrett and contributors               }
{                                                                           }
{           vincent@finalbuilder.com                                        }
{           https://www.finalbuilder.com                                    }
{                                                                           }
{                                                                           }
{***************************************************************************}
{                                                                           }
{  Licensed under the Apache License, Version 2.0 (the "License");          }
{  you may not use this file except in compliance with the License.         }
{  You may obtain a copy of the License at                                  }
{                                                                           }
{      http://www.apache.org/licenses/LICENSE-2.0                           }
{                                                                           }
{  Unless required by applicable law or agreed to in writing, software      }
{  distributed under the License is distributed on an "AS IS" BASIS,        }
{  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. }
{  See the License for the specific language governing permissions and      }
{  limitations under the License.                                           }
{                                                                           }
{***************************************************************************}

unit DPM.Core.Package.Installer;

//TODO : Lots of common code between install and restore - refactor!

interface

uses
  VSoft.Awaitable,
  Spring.Collections,
  DPM.Core.Types,
  DPM.Core.Logging,
  DPM.Core.Options.Cache,
  DPM.Core.Options.Install,
  DPM.Core.Options.Uninstall,
  DPM.Core.Options.Restore,
  DPM.Core.Project.Interfaces,
  DPM.Core.Spec.Interfaces,
  DPM.Core.Package.Interfaces,
  DPM.Core.Configuration.Interfaces,
  DPM.Core.Repository.Interfaces,
  DPM.Core.Cache.Interfaces,
  DPM.Core.Dependency.Interfaces,
  DPM.Core.Compiler.Interfaces;

type
  TPackageInstaller = class(TInterfacedObject, IPackageInstaller)
  private
    FLogger : ILogger;
    FConfigurationManager : IConfigurationManager;
    FRepositoryManager : IPackageRepositoryManager;
    FPackageCache : IPackageCache;
    FDependencyResolver : IDependencyResolver;
    FContext : IPackageInstallerContext;
    FCompilerFactory : ICompilerFactory;
  protected
    function GetPackageInfo(const cancellationToken : ICancellationToken; const packageId : IPackageId) : IPackageInfo;

    function CollectSearchPaths(const resolvedPackages : IList<IPackageInfo>; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform; const searchPaths : IList<string> ) : boolean;

    procedure GenerateSearchPaths(const compilerVersion : TCompilerVersion; const platform : TDPMPlatform; packageSpec : IPackageSpec; const searchPaths : IList<string>);

    function DownloadPackages(const cancellationToken : ICancellationToken; const resolvedPackages : IList<IPackageInfo>; var packageSpecs : IDictionary<string, IPackageSpec>) : boolean;

    function CollectPlatformsFromProjectFiles(const options : TInstallOptions; const projectFiles : TArray <string> ; const config : IConfiguration) : boolean;

    function GetCompilerVersionFromProjectFiles(const options : TInstallOptions; const projectFiles : TArray <string> ; const config : IConfiguration) : boolean;


    function CompilePackage(const cancellationToken : ICancellationToken; const compiler : ICompiler; const packageInfo : IPackageInfo; const packageSpec : IPackageSpec) : boolean;


    function DoRestoreProject(const cancellationToken : ICancellationToken; const options : TRestoreOptions; const projectFile : string; const projectEditor : IProjectEditor; const platform : TDPMPlatform; const config : IConfiguration) : boolean;

    function DoInstallPackage(const cancellationToken : ICancellationToken; const options : TInstallOptions; const projectFile : string; const projectEditor : IProjectEditor; const platform : TDPMPlatform; const config : IConfiguration) : boolean;

    function DoUninstallFromProject(const cancellationToken : ICancellationToken; const options : TUnInstallOptions; const projectFile : string; const projectEditor : IProjectEditor; const platform : TDPMPlatform; const config : IConfiguration) : boolean;


    function DoCachePackage(const cancellationToken : ICancellationToken; const options : TCacheOptions; const platform : TDPMPlatform) : boolean;

    //works out what compiler/platform then calls DoInstallPackage
    function InstallPackage(const cancellationToken : ICancellationToken; const options : TInstallOptions; const projectFile : string; const config : IConfiguration) : boolean;

    //user specified a package file - will install for single compiler/platform - calls InstallPackage
    function InstallPackageFromFile(const cancellationToken : ICancellationToken; const options : TInstallOptions; const projectFiles : TArray <string> ; const config : IConfiguration) : boolean;

    //resolves package from id - calls InstallPackage
    function InstallPackageFromId(const cancellationToken : ICancellationToken; const options : TInstallOptions; const projectFiles : TArray <string> ; const config : IConfiguration) : boolean;

    //calls either InstallPackageFromId or InstallPackageFromFile depending on options.
    function Install(const cancellationToken : ICancellationToken; const options : TInstallOptions) : Boolean;

    function UnInstall(const cancellationToken : ICancellationToken; const options : TUnInstallOptions) : boolean;

    function UnInstallFromProject(const cancellationToken : ICancellationToken; const options : TUnInstallOptions; const projectFile : string; const config : IConfiguration) : Boolean;


    function RestoreProject(const cancellationToken : ICancellationToken; const options : TRestoreOptions; const projectFile : string; const config : IConfiguration) : Boolean;

    //calls restore project
    function Restore(const cancellationToken : ICancellationToken; const options : TRestoreOptions) : Boolean;

    function Remove(const cancellationToken : ICancellationToken; const options : TUninstallOptions) : boolean;


    function Cache(const cancellationToken : ICancellationToken; const options : TCacheOptions) : boolean;

    function Context : IPackageInstallerContext;

  public
    constructor Create(const logger : ILogger; const configurationManager : IConfigurationManager;
      const repositoryManager : IPackageRepositoryManager; const packageCache : IPackageCache;
      const dependencyResolver : IDependencyResolver; const context : IPackageInstallerContext;
      const compilerFactory : ICompilerFactory);
  end;

implementation

uses
  System.IOUtils,
  System.Types,
  System.SysUtils,
  Spring.Collections.Extensions,
  DPM.Core.Constants,
  DPM.Core.Utils.Path,
  DPM.Core.Utils.System,
  DPM.Core.Project.Editor,
  DPM.Core.Project.GroupProjReader,
  DPM.Core.Project.PackageReference,
  DPM.Core.Options.List,
  DPM.Core.Dependency.Graph,
  DPM.Core.Dependency.Version,
  DPM.Core.Package.Metadata,
  DPM.Core.Spec.Reader;


{ TPackageInstaller }


function TPackageInstaller.Cache(const cancellationToken : ICancellationToken; const options : TCacheOptions) : boolean;
var
  config : IConfiguration;
  platform : TDPMPlatform;
  platforms : TDPMPlatforms;
begin
  result := false;
  if (not options.Validated) and (not options.Validate(FLogger)) then
    exit
  else if not options.IsValid then
    exit;

  config := FConfigurationManager.LoadConfig(options.ConfigFile);
  if config = nil then
    exit;

  FPackageCache.Location := config.PackageCacheLocation;
  if not FRepositoryManager.Initialize(config) then
  begin
    FLogger.Error('Unable to initialize the repository manager.');
    exit;
  end;

  platforms := options.Platforms;

  if platforms = [] then
    platforms := AllPlatforms(options.CompilerVersion);

  result := true;
  for platform in platforms do
  begin
    if cancellationToken.IsCancelled then
      exit;
    options.Platforms := [platform];
    result := DoCachePackage(cancellationToken, options, platform) and result;
  end;
end;

function TPackageInstaller.CollectPlatformsFromProjectFiles(const options : TInstallOptions; const projectFiles : TArray <string> ; const config : IConfiguration) : boolean;
var
  projectFile : string;
  projectEditor : IProjectEditor;
begin
  result := true;
  for projectFile in projectFiles do
  begin
    projectEditor := TProjectEditor.Create(FLogger, config, options.CompilerVersion);
    result := result and projectEditor.LoadProject(projectFile);
    if result then
      options.Platforms := options.Platforms + projectEditor.Platforms;
  end;

end;

function TPackageInstaller.CollectSearchPaths(const resolvedPackages : IList<IPackageInfo>; const compilerVersion : TCompilerVersion; const platform : TDPMPlatform; const searchPaths : IList<string> ) : boolean;
var
  packageInfo : IPackageInfo;
  packageMetadata : IPackageMetadata;
  packageSearchPath : IPackageSearchPath;
  packageBasePath : string;
begin
  result := true;

  for packageInfo in resolvedPackages do
  begin
    packageMetadata := FPackageCache.GetPackageMetadata(packageInfo);
    if packageMetadata = nil then
    begin
      FLogger.Error('Unable to get metadata for package ' + packageInfo.ToString);
      exit(false);
    end;
    packageBasePath := packageMetadata.Id + PathDelim + packageMetadata.Version.ToStringNoMeta + PathDelim;

    for packageSearchPath in packageMetadata.SearchPaths do
      searchPaths.Add(packageBasePath + packageSearchPath.Path);
  end;
end;

function TPackageInstaller.CompilePackage(const cancellationToken: ICancellationToken; const compiler: ICompiler; const packageInfo : IPackageInfo; const packageSpec : IPackageSpec): boolean;
var
  buildEntry : ISpecBuildEntry;
begin
  result := true;
  for buildEntry in packageSpec.TargetPlatform.BuildEntries do
  begin
    FLogger.Debug('Compiling package : ' + buildEntry.Project);
  end;


end;

function TPackageInstaller.Context : IPackageInstallerContext;
begin
  result := FContext;
end;

constructor TPackageInstaller.Create(const logger : ILogger; const configurationManager : IConfigurationManager;
  const repositoryManager : IPackageRepositoryManager; const packageCache : IPackageCache;
  const dependencyResolver : IDependencyResolver; const context : IPackageInstallerContext;
  const compilerFactory : ICompilerFactory);
begin
  FLogger := logger;
  FConfigurationManager := configurationManager;
  FRepositoryManager := repositoryManager;
  FPackageCache := packageCache;
  FDependencyResolver := dependencyResolver;
  FContext := context;
  FCompilerFactory := compilerFactory;
end;

function TPackageInstaller.GetPackageInfo(const cancellationToken : ICancellationToken; const packageId : IPackageId) : IPackageInfo;
begin
  result := FPackageCache.GetPackageInfo(cancellationToken, packageId); //faster
  if result = nil then
    result := FRepositoryManager.GetPackageInfo(cancellationToken, packageId); //slower
end;

function TPackageInstaller.DoCachePackage(const cancellationToken : ICancellationToken; const options : TCacheOptions; const platform : TDPMPlatform) : boolean;
var
  packageIdentity : IPackageIdentity;
  searchResult : IList<IPackageIdentity>;
  packageFileName : string;
begin
  result := false;
  if not options.Version.IsEmpty then
    //sourceName will be empty if we are installing the package from a file
    packageIdentity := TPackageIdentity.Create(options.PackageId, '', options.Version, options.CompilerVersion, platform, '')
  else
  begin
    //no version specified, so we need to get the latest version available;
    searchResult := FRepositoryManager.List(cancellationToken, options);
    packageIdentity := searchResult.FirstOrDefault;
    if packageIdentity = nil then
    begin
      FLogger.Error('Package [' + options.PackageId + '] for platform [' + DPMPlatformToString(platform) + '] not found on any sources');
      exit;
    end;
  end;
  FLogger.Information('Caching package ' + packageIdentity.ToString);

  if not FPackageCache.EnsurePackage(packageIdentity) then
  begin
    //not in the cache, so we need to get it from the the repository
    if not FRepositoryManager.DownloadPackage(cancellationToken, packageIdentity, FPackageCache.PackagesFolder, packageFileName) then
    begin
      FLogger.Error('Failed to download package [' + packageIdentity.ToString + ']');
      exit;
    end;
    if not FPackageCache.InstallPackageFromFile(packageFileName, true) then
    begin
      FLogger.Error('Failed to cache package file [' + packageFileName + '] into the cache');
      exit;
    end;
  end;
  result := true;

end;

procedure BuildGraph(const packageReference : IPackageReference; const parentNode : IGraphNode);
var
  childNode : IGraphNode;
  childRef : IPackageReference;
begin
  childNode := parentNode.AddChildNode(packageReference.Id, packageReference.Version, packageReference.Range);

  if (packageReference.Dependencies <> nil) and (packageReference.Dependencies.Any) then
  begin
    for childRef in packageReference.Dependencies do
    begin
      BuildGraph(childRef, childNode);
    end;
  end;
end;



procedure GeneratePackageReferences(const parentNode : IGraphNode; const parentRef : IPackageReference; const packageReferences : IList<IPackageReference>;
  const compilerVersion : TCompilerVersion; const platform : TDPMPlatform);
var
  childNode : IGraphNode;
  packageRef : IPackageReference;
begin
  if not parentNode.HasChildren then
    exit;

  for childNode in parentNode.ChildNodes do
  begin
    packageRef := TPackageReference.Create(childNode.Id, childNode.SelectedVersion, platform, compilerVersion, childNode.SelectedOn, not childNode.IsTopLevel);
    if childNode.IsTopLevel then
      packageReferences.Add(packageRef)
    else
      parentRef.Dependencies.Add(packageRef);

    if childNode.HasChildren then
      GeneratePackageReferences(childNode, packageRef, packageReferences, compilerVersion, platform);
  end;
end;

//recursively add package references.
procedure AddPackageReference(const packageRef : IPackageReference; const packageReferences : IList<IPackageReference>; const conflictDetect : IDictionary < string, TPackageVersion > );
var
  dependency : IPackageReference;
  existingVer : TPackageVersion;
begin
  //sanity check that someone hasn't messed with the package references
  //or that a bug has messed it up.
  //this also dedupes.
  if conflictDetect.TryGetValue(LowerCase(packageRef.Id), existingVer) then
  begin
    if conflictDetect[LowerCase(packageRef.Id)] <> packageRef.Version then
      raise Exception.Create('Conflicting package references for package [' + packageRef.Id + '] versions [' + packageRef.Version.ToString + ', ' + existingVer.ToString + ']');
  end
  else
  begin
    conflictDetect[LowerCase(packageRef.Id)] := packageRef.Version;
    packageReferences.Add(packageRef);
    if packageRef.Dependencies <> nil then
    begin
      for dependency in packageRef.Dependencies do
        AddPackageReference(dependency, packageReferences, conflictDetect);
    end;
  end;
end;



function TPackageInstaller.DoInstallPackage(const cancellationToken : ICancellationToken; const options : TInstallOptions; const projectFile : string; const projectEditor : IProjectEditor; const platform : TDPMPlatform; const config : IConfiguration) : boolean;
var
  newPackageIdentity : IPackageIdentity;
  searchResult : IList<IPackageIdentity>;
  packageFileName : string;
  packageInfo : IPackageInfo; //includes dependencies;
  existingPackageRef : IPackageReference;
  packageReference : IPackageReference;
  projectPackageReferences : IList<IPackageReference>;
  packageReferences : IList<IPackageReference>;
  packageSpecs : IDictionary<string, IPackageSpec>;

  conflictDetect : IDictionary<string, TPackageVersion>;
  projectPackageInfos : IList<IPackageInfo>;
  projectPackageInfo : IPackageInfo;

  projectReferences : IList<TProjectReference>;

  resolvedPackages : IList<IPackageInfo>;
  packageSearchPaths : IList<string>;
  dependencyGraph : IGraphNode;
  childNode : IGraphNode;

  packageCompiler : ICompiler;

begin
  result := false;
  //if the user specified a version, either the on the command line or via a file then we will use that
  if not options.Version.IsEmpty then
    //sourceName will be empty if we are installing the package from a file
    newPackageIdentity := TPackageIdentity.Create(options.PackageId, '', options.Version, options.CompilerVersion, platform, '')
  else
  begin
    //no version specified, so we need to get the latest version available;
    searchResult := FRepositoryManager.List(cancellationToken, options);
    newPackageIdentity := searchResult.FirstOrDefault;
    if newPackageIdentity = nil then
    begin
      FLogger.Error('Package [' + options.PackageId + '] for platform [' + DPMPlatformToString(platform) + '] not found on any sources');
      exit;
    end;
  end;
  FLogger.Information('Installing package ' + newPackageIdentity.ToString);

  projectPackageReferences := TCollections.CreateList<IPackageReference>;
  packageReferences := TCollections.CreateList<IPackageReference>;
  conflictDetect := TCollections.CreateDictionary < string, TPackageVersion > ;
  dependencyGraph := TGraphNode.CreateRoot;


  //get the direct dependencies for the platform.
  projectPackageReferences.AddRange(projectEditor.PackageReferences.Where(
      function(const packageReference : IPackageReference) : boolean
      begin
        result := platform = packageReference.Platform;
      end));

  //see if we have the package installed already (direct dependency, any version)
  existingPackageRef := projectPackageReferences.FirstOrDefault(
    function(const packageRef : IPackageReference) : boolean
    begin
      result := SameText(newPackageIdentity.Id, packageRef.Id);
    end);

  if (existingPackageRef <> nil) then
  begin
    //if it's installed already and we're not forcing it to install then we're done.
    if not options.Force  then
    begin
      //Note this error won't show from the IDE as we always force install from the IDE.
      FLogger.Error('Package [' + newPackageIdentity.ToString + '] is already installed. Use option -force to force reinstall.');
      exit;
    end;
    //remove it so we can force resolution to happen later.
    projectPackageReferences.Remove(existingPackageRef);
  end;

  //flatten & dedupe the references and build our graph.
  for packageReference in projectPackageReferences do
  //We shouldn't need this, projectPackageReferences already contains only the desired platforn references
//    .Where(
//    function(const packageReference : IPackageReference) : boolean
//    begin
//      result := platform = packageReference.Platform;
//    end) do
  begin
    BuildGraph(packageReference, dependencyGraph);
    AddPackageReference(packageReference, packageReferences, conflictDetect);
  end;

  //check to see if trying to install something that is already a transitive dependency.
  existingPackageRef := packageReferences.FirstOrDefault(
    function(const packageRef : IPackageReference) : boolean
    begin
      result := SameText(newPackageIdentity.Id, packageRef.Id);
      // should already be correct platform  - result := result and (newPackageIdentity.Platform = packageRef.Platform);
    end);

  //We could have a transitive dependency that is being promoted.
  if (existingPackageRef <> nil) then
  begin
    childNode := dependencyGraph.FindFirstNode(existingPackageRef.Id);
    if (childNode <> nil) and (childNode.IsTopLevel) then
    begin
      //if it's a top level dependency, then the user must use force to re-install
      if not options.Force then
      begin
        FLogger.Error('Package [' + newPackageIdentity.ToString + '] is already installed. Use option -force to force reinstall.');
        exit;
      end
      else
        dependencyGraph.RemoveNode(childNode);
    end;
    //if we got here we are either forcing the install or it's transitive dependency, either
    //way we need to remove all references to it.
    packageReferences.Remove(existingPackageRef);

    //now deal with a transitive dependency being promoted to the top level.
    //there may be multiple instances in the dependency graph, this should remove
    //all instances.
    childNode := dependencyGraph.FindFirstNode(existingPackageRef.Id);
    while childNode <> nil do
    begin
      dependencyGraph.RemoveNode(childNode);
      childNode := dependencyGraph.FindFirstNode(existingPackageRef.Id);
    end;
  end;


  if not FPackageCache.EnsurePackage(newPackageIdentity) then
  begin
    //not in the cache, so we need to get it from the the repository
    if not FRepositoryManager.DownloadPackage(cancellationToken, newPackageIdentity, FPackageCache.PackagesFolder, packageFileName) then
    begin
      FLogger.Error('Failed to download package [' + newPackageIdentity.ToString + ']');
      exit;
    end;
    if not FPackageCache.InstallPackageFromFile(packageFileName, true) then
    begin
      FLogger.Error('Failed to install package file [' + packageFileName + '] into the cache');
      exit;
    end;
  end;

  //get the package info, which has the dependencies.
  packageInfo := GetPackageInfo(cancellationToken, newPackageIdentity);

  //turn them into packageIdentity's so we can get their Info/dependencies

  projectPackageInfos := TCollections.CreateList<IPackageInfo>;
  //TODO : When we get to http repos, this might be slow, perhaps parallel for might
  for packageReference in packageReferences do
  begin
    projectPackageInfo := GetPackageInfo(cancellationToken, packageReference);
    if projectPackageInfo = nil then
    begin
      FLogger.Error('Unable to resolve package : ' + newPackageIdentity.ToString);
      exit;
    end;
    projectPackageInfos.Add(projectPackageInfo);
  end;

  projectReferences := TCollections.CreateList<TProjectReference>;
  projectReferences.AddRange(TEnumerable.Select<IPackageInfo, TProjectReference>(projectPackageInfos,
    function(const info : IPackageInfo) : TProjectReference
    var
      node : IGraphNode;
      parentNode : IGraphNode;
    begin
      result.Package := info;
      node := dependencyGraph.FindFirstNode(info.Id);
      if node <> nil then
      begin
        result.VersionRange := node.SelectedOn;
        parentNode := node.Parent;
        result.ParentId := parentNode.Id;
      end
      else
      begin
        result.VersionRange := TVersionRange.Empty;
        result.ParentId := 'root';
      end;
    end));


  result := FDependencyResolver.ResolveForInstall(cancellationToken, options, packageInfo, projectReferences, dependencyGraph, packageInfo.CompilerVersion, platform, resolvedPackages);
  if not result then
    exit;

  //TODO : The code from here on is the same for install/uninstall/restore - refactor!!!

  if resolvedPackages = nil then
  begin
    FLogger.Error('Resolver returned no packages!');
    exit(false);
  end;

  packageInfo := resolvedPackages.FirstOrDefault(
    function(const info : IPackageInfo) : boolean
    begin
      result := SameText(info.Id, packageInfo.Id);
    end);

  if packageInfo = nil then
  begin
    FLogger.Error('Something went wrong, resultution did not return installed package!');
    exit(false);
  end;

  //downloads the package files to the cache if they are not already there and
  //returns the deserialized dspec as we need it for search paths and
  result := DownloadPackages(cancellationToken, resolvedPackages, packageSpecs);
  if not result then
    exit;


//  packageCompiler := FCompilerFactory.CreateCompiler(options.CompilerVersion, platform);
//
//  //build the dependency graph in the correct order.
//  dependencyGraph.VisitDFS(
//    procedure(const node : IGraphNode)
//    var
//      pkgInfo : IPackageInfo;
//      spec : IPackageSpec;
//    begin
//      Assert(node.IsRoot = false, 'graph should not visit root node');
//
//      pkgInfo := resolvedPackages.FirstOrDefault(
//        function(const value : IPackageInfo) : boolean
//        begin
//          result := SameText(value.Id, node.Id);
//        end);
//      //if it's not found that means we have already processed the package elsewhere in the graph
//      if pkgInfo = nil then
//        exit;
//      //removing it so we don't process it again
//      resolvedPackages.Remove(pkgInfo);
//      spec := packageSpecs[LowerCase(node.Id)];
//      Assert(spec <> nil);
//      if spec.TargetPlatform.BuildEntries.Any then
//      begin
//        //we need to build the package.
//      end;
//      if spec.TargetPlatform.DesignFiles.Any then
//      begin
//        //we have design time packages to install.
//
//      end;
//
//    end);


  packageSearchPaths := TCollections.CreateList <string> ;
  packageCompiler := FCompilerFactory.CreateCompiler(options.CompilerVersion, platform);

  try
  //build the dependency graph in the correct order.
  dependencyGraph.VisitDFS(
    procedure(const node : IGraphNode)
    var
      pkgInfo : IPackageInfo;
      spec : IPackageSpec;
    begin
      Assert(node.IsRoot = false, 'graph should not visit root node');

      pkgInfo := resolvedPackages.FirstOrDefault(
        function(const value : IPackageInfo) : boolean
        begin
          result := SameText(value.Id, node.Id);
        end);
      //if it's not found that means we have already processed the package elsewhere in the graph
      if pkgInfo = nil then
        exit;
      //removing it so we don't process it again
      resolvedPackages.Remove(pkgInfo);

      spec := packageSpecs[LowerCase(node.Id)];
      Assert(spec <> nil);
      if spec.TargetPlatform.BuildEntries.Any then
      begin
        //we need to build the package.
        if not CompilePackage(cancellationToken, packageCompiler, pkgInfo, spec) then
          raise Exception.Create('Comping package [' + pkgInfo.ToIdVersionString + '] failed.' );
      end;

      if spec.TargetPlatform.DesignFiles.Any then
      begin
        //we have design time packages to install.
      end;

      GenerateSearchPaths(options.CompilerVersion, platform, spec, packageSearchPaths);
    end);
  except
    on e : Exception do
    begin
      FLogger.Error(e.Message);
      exit;
    end;
  end;

  if not projectEditor.AddSearchPaths(platform, packageSearchPaths, config.PackageCacheLocation) then
    exit;

  packageReferences.Clear;
  GeneratePackageReferences(dependencyGraph, nil, packageReferences, options.CompilerVersion, platform);

  projectEditor.UpdatePackageReferences(packageReferences, platform);
  result := projectEditor.SaveProject();

end;


function TPackageInstaller.DoRestoreProject(const cancellationToken : ICancellationToken; const options : TRestoreOptions; const projectFile : string; const projectEditor : IProjectEditor; const platform : TDPMPlatform; const config : IConfiguration) : boolean;
var
  packageReference : IPackageReference;
  packageReferences : IList<IPackageReference>;
  packageSpecs : IDictionary<string, IPackageSpec>;
  projectPackageInfos : IList<IPackageInfo>;
  projectPackageInfo : IPackageInfo;
  resolvedPackages : IList<IPackageInfo>;
  packageSearchPaths : IList<string>;
  conflictDetect : IDictionary<string, TPackageVersion>;
  dependencyGraph : IGraphNode;
  projectReferences : IList<TProjectReference>;

begin
  result := false;

  //get the packages already referenced by the project for the platform
  packageReferences := TCollections.CreateList<IPackageReference>;

  conflictDetect := TCollections.CreateDictionary < string, TPackageVersion > ;

  dependencyGraph := TGraphNode.CreateRoot;

  for packageReference in projectEditor.PackageReferences.Where(
    function(const packageReference : IPackageReference) : boolean
    begin
      result := platform = packageReference.Platform;
    end) do
  begin
    BuildGraph(packageReference, dependencyGraph);
    AddPackageReference(packageReference, packageReferences, conflictDetect);
  end;

  if not packageReferences.Any then
  begin
    FLogger.Information('No package references found in project [' + projectFile + '] for platform [' + DPMPlatformToString(platform) + '] - nothing to do.');
    //TODO : Should this fail with an error? It's a noop
    exit(true);
  end;

  projectPackageInfos := TCollections.CreateList<IPackageInfo>;
  for packageReference in packageReferences do
  begin
    projectPackageInfo := GetPackageInfo(cancellationToken, packageReference);
    if projectPackageInfo = nil then
    begin
      FLogger.Error('Unable to resolve package : ' + packageReference.ToString);
      exit;
    end;
    projectPackageInfos.Add(projectPackageInfo);
  end;

  projectReferences := TCollections.CreateList<TProjectReference>;

  projectReferences.AddRange(TEnumerable.Select<IPackageInfo, TProjectReference>(projectPackageInfos,
    function(const info : IPackageInfo) : TProjectReference
    var
      node : IGraphNode;
      parentNode : IGraphNode;
    begin
      result.Package := info;
      node := dependencyGraph.FindFirstNode(info.Id);
      if node <> nil then
      begin
        result.VersionRange := node.SelectedOn;
        parentNode := node.Parent;
        result.ParentId := parentNode.Id;
      end
      else
      begin
        result.VersionRange := TVersionRange.Empty;
        result.ParentId := 'root';
      end;
    end));




  //NOTE : The resolver may modify the graph.
  result := FDependencyResolver.ResolveForRestore(cancellationToken, options, projectReferences, dependencyGraph, options.CompilerVersion, platform, resolvedPackages);
  if not result then
    exit;

  if resolvedPackages = nil then
  begin
    FLogger.Error('Resolver returned no packages!');
    exit(false);
  end;

  for projectPackageInfo in resolvedPackages do
  begin
    FLogger.Information('Resolved : ' + projectPackageInfo.ToIdVersionString);
  end;

  result := DownloadPackages(cancellationToken, resolvedPackages, packageSpecs );
  if not result then
    exit;

  //TODO : Detect if anything has actually changed and only do this if we need to
  packageSearchPaths := TCollections.CreateList <string> ;

  if not CollectSearchPaths(resolvedPackages, projectEditor.CompilerVersion, platform, packageSearchPaths) then
    exit;

  if not projectEditor.AddSearchPaths(platform, packageSearchPaths, config.PackageCacheLocation) then
    exit;

  packageReferences.Clear;
  GeneratePackageReferences(dependencyGraph, nil, packageReferences, options.CompilerVersion, platform);

  projectEditor.UpdatePackageReferences(packageReferences, platform);
  result := projectEditor.SaveProject();

end;

function TPackageInstaller.DoUninstallFromProject(const cancellationToken: ICancellationToken; const options: TUnInstallOptions; const projectFile: string;
                                                  const projectEditor: IProjectEditor; const platform: TDPMPlatform; const config: IConfiguration): boolean;
var
  packageReference : IPackageReference;
  packageReferences : IList<IPackageReference>;
  projectPackageInfos : IList<IPackageInfo>;
  projectPackageInfo : IPackageInfo;
  resolvedPackages : IList<IPackageInfo>;
  packageSpecs : IDictionary<string, IPackageSpec>;
  packageSearchPaths : IList<string>;
  conflictDetect : IDictionary<string, TPackageVersion>;
  dependencyGraph : IGraphNode;
  projectReferences : IList<TProjectReference>;
  foundReference : IPackageReference;
begin
  result := false;

  //get the packages already referenced by the project for the platform
  packageReferences := TCollections.CreateList<IPackageReference>;

  conflictDetect := TCollections.CreateDictionary < string, TPackageVersion > ;

  dependencyGraph := TGraphNode.CreateRoot;

  foundReference := nil;
  for packageReference in projectEditor.PackageReferences.Where(
    function(const packageReference : IPackageReference) : boolean
    begin
      result := platform = packageReference.Platform;
    end) do
  begin
    if not SameText(packageReference.Id, options.PackageId) then
    begin
      BuildGraph(packageReference, dependencyGraph);
      AddPackageReference(packageReference, packageReferences, conflictDetect);
    end
    else
      foundReference := packageReference;
  end;

  if foundReference = nil then
  begin
    FLogger.Information('Package [' + options.PackageId + '] was not referenced in project [' + projectFile + '] for platform [' + DPMPlatformToString(platform) + '] - nothing to do.');
    //TODO : Should this fail with an error? It's a noop
    exit(true);
  end;

  projectEditor.PackageReferences.Remove(foundReference);

  //NOTE : Even though there might be no package references after this, we still need to do the restore process to update search paths etc.

  projectPackageInfos := TCollections.CreateList<IPackageInfo>;
  for packageReference in packageReferences do
  begin
    projectPackageInfo := GetPackageInfo(cancellationToken, packageReference);
    if projectPackageInfo = nil then
    begin
      FLogger.Error('Unable to resolve package : ' + packageReference.ToString);
      exit;
    end;
    projectPackageInfos.Add(projectPackageInfo);
  end;


  projectReferences := TCollections.CreateList<TProjectReference>;

  if packageReferences.Any then
    projectReferences.AddRange(TEnumerable.Select<IPackageInfo, TProjectReference>(projectPackageInfos,
      function(const info : IPackageInfo) : TProjectReference
      var
        node : IGraphNode;
        parentNode : IGraphNode;
      begin
        result.Package := info;
        node := dependencyGraph.FindFirstNode(info.Id);
        if node <> nil then
        begin
          result.VersionRange := node.SelectedOn;
          parentNode := node.Parent;
          result.ParentId := parentNode.Id;
        end
        else
        begin
          result.VersionRange := TVersionRange.Empty;
          result.ParentId := 'root';
        end;
      end));


  //NOTE : The resolver may modify the graph.
  result := FDependencyResolver.ResolveForRestore(cancellationToken, options, projectReferences, dependencyGraph, options.CompilerVersion, platform, resolvedPackages);
  if not result then
    exit;

  if resolvedPackages = nil then
  begin
    FLogger.Error('Resolver returned no packages!');
    exit(false);
  end;

  if resolvedPackages.Any then
  begin
    for projectPackageInfo in resolvedPackages do
    begin
      FLogger.Information('Resolved : ' + projectPackageInfo.ToIdVersionString);
    end;

    result := DownloadPackages(cancellationToken, resolvedPackages, packageSpecs );
    if not result then
      exit;
  end;

  //TODO : Detect if anything has actually changed and only do this if we need to
  packageSearchPaths := TCollections.CreateList <string> ;

  if not CollectSearchPaths(resolvedPackages, projectEditor.CompilerVersion, platform, packageSearchPaths) then
    exit;

  if not projectEditor.AddSearchPaths(platform, packageSearchPaths, config.PackageCacheLocation) then
    exit;

  packageReferences.Clear;
  GeneratePackageReferences(dependencyGraph, nil, packageReferences, options.CompilerVersion, platform);

  projectEditor.UpdatePackageReferences(packageReferences, platform);
  result := projectEditor.SaveProject();
end;

function TPackageInstaller.DownloadPackages(const cancellationToken : ICancellationToken; const resolvedPackages : IList<IPackageInfo>; var packageSpecs : IDictionary<string, IPackageSpec>) : boolean;
var
  packageInfo : IPackageInfo;
  packageFileName : string;
  spec : IPackageSpec;
begin
  result := false;
  packageSpecs := TCollections.CreateDictionary<string, IPackageSpec>;

  for packageInfo in resolvedPackages do
  begin
    if cancellationToken.IsCancelled then
      exit;

    if not FPackageCache.EnsurePackage(packageInfo) then
    begin
      //not in the cache, so we need to get it from the the repository
      if not FRepositoryManager.DownloadPackage(cancellationToken, packageInfo, FPackageCache.PackagesFolder, packageFileName) then
      begin
        FLogger.Error('Failed to download package [' + packageInfo.ToString + ']');
        exit;
      end;
      if not FPackageCache.InstallPackageFromFile(packageFileName, true) then
      begin
        FLogger.Error('Failed to install package file [' + packageFileName + '] into the cache');
        exit;
      end;
      if cancellationToken.IsCancelled then
        exit;
    end;
    if not packageSpecs.ContainsKey(LowerCase(packageInfo.Id)) then
    begin
      spec := FPackageCache.GetPackageSpec(packageInfo);
      packageSpecs[LowerCase(packageInfo.Id)] := spec;
    end;

  end;
  result := true;

end;

function TPackageInstaller.InstallPackage(const cancellationToken : ICancellationToken; const options : TInstallOptions; const projectFile : string; const config : IConfiguration) : boolean;
var
  projectEditor : IProjectEditor;
  platforms : TDPMPlatforms;
  platform : TDPMPlatform;
  platformResult : boolean;
  ambiguousProjectVersion : boolean;
  ambiguousVersions : string;
begin
  result := false;

  //make sure we can parse the dproj
  projectEditor := TProjectEditor.Create(FLogger, config, options.CompilerVersion);
  if not projectEditor.LoadProject(projectFile) then
  begin
    FLogger.Error('Unable to load project file, cannot continue');
    exit;
  end;

  ambiguousProjectVersion := IsAmbigousProjectVersion(projectEditor.ProjectVersion, ambiguousVersions);

  if ambiguousProjectVersion and (options.CompilerVersion = TCompilerVersion.UnknownVersion) then
    FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] is ambiguous (' + ambiguousVersions  +'), recommend specifying compiler version on command line.');

  //if the compiler version was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that version.
  if options.CompilerVersion <> TCompilerVersion.UnknownVersion then
  begin
    if projectEditor.CompilerVersion <> options.CompilerVersion then
    begin
      if not ambiguousProjectVersion then
        FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] does not match the compiler version.');
      projectEditor.CompilerVersion := options.CompilerVersion;
    end;
  end
  else
    options.CompilerVersion := projectEditor.CompilerVersion;


  //if the platform was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that platform.
  if options.Platforms <> [] then
  begin
    platforms := options.Platforms * projectEditor.Platforms; //gets the intersection of the two sets.
    if platforms = [] then //no intersection
    begin
      FLogger.Warning('Skipping project file [' + projectFile + '] as it does not match target specified platforms.');
      exit;
    end;
    //TODO : what if only some of the platforms are supported, what should we do?
  end
  else
    platforms := projectEditor.Platforms;

  result := true;
  for platform in platforms do
  begin
    if cancellationToken.IsCancelled then
      exit;

    options.Platforms := [platform];
    FLogger.Information('Installing [' + options.SearchTerms + '-' + DPMPlatformToString(platform) + '] into [' + projectFile + ']', true);
    platformResult := DoInstallPackage(cancellationToken, options, projectFile, projectEditor, platform, config);
    if not platformResult then
      FLogger.Error('Install failed for [' + options.SearchTerms + '-' + DPMPlatformToString(platform) + ']')
    else
      FLogger.Success('Install succeeded for [' + options.SearchTerms + '-' + DPMPlatformToString(platform) + ']', true);

    result := platformResult and result;
    FLogger.Information('');
  end;

end;

procedure TPackageInstaller.GenerateSearchPaths(const compilerVersion: TCompilerVersion; const platform: TDPMPlatform; packageSpec: IPackageSpec;
                                               const searchPaths: IList<string>);
var
  packageBasePath : string;
  packageSearchPath : ISpecSearchPath;
begin
  packageBasePath := packageSpec.MetaData.Id + PathDelim + packageSpec.MetaData.Version.ToStringNoMeta + PathDelim;

  for packageSearchPath  in packageSpec.TargetPlatform.SearchPaths do
      searchPaths.Add(packageBasePath + packageSearchPath.Path);
end;

function TPackageInstaller.GetCompilerVersionFromProjectFiles(const options : TInstallOptions; const projectFiles : TArray <string> ; const config : IConfiguration) : boolean;
var
  projectFile : string;
  projectEditor : IProjectEditor;
  compilerVersion : TCompilerVersion;
  bFirst : boolean;
begin
  result := true;
  compilerVersion := TCompilerVersion.UnknownVersion;
  bFirst := true;
  for projectFile in projectFiles do
  begin
    projectEditor := TProjectEditor.Create(FLogger, config, options.CompilerVersion);
    result := result and projectEditor.LoadProject(projectFile);
    if result then
    begin
      if not bFirst then
      begin
        if projectEditor.CompilerVersion <> compilerVersion then
        begin
          FLogger.Error('Projects are not all the for same compiler version.');
          result := false;
        end;
      end;
      compilerVersion := options.CompilerVersion;
      options.CompilerVersion := projectEditor.CompilerVersion;
      bFirst := false;
    end;
  end;
end;

function TPackageInstaller.Install(const cancellationToken : ICancellationToken; const options : TInstallOptions) : Boolean;
var
  projectFiles : TArray<string>;
  config : IConfiguration;
begin
  result := false;
  try
    if (not options.Validated) and (not options.Validate(FLogger)) then
      exit
    else if not options.IsValid then
      exit;

    config := FConfigurationManager.LoadConfig(options.ConfigFile);
    if config = nil then
      exit;

    FPackageCache.Location := config.PackageCacheLocation;
    if not FRepositoryManager.Initialize(config) then
    begin
      FLogger.Error('Unable to initialize the repository manager.');
      exit;
    end;

    if not FRepositoryManager.HasSources then
    begin
      FLogger.Error('No package sources are defined. Use `dpm sources add` command to add a package source.');
      exit;
    end;


    if FileExists(options.ProjectPath) then
    begin
      if ExtractFileExt(options.ProjectPath) <> '.dproj' then
      begin
        FLogger.Error('Unsupported project file type [' + options.ProjectPath + ']');
      end;
      SetLength(projectFiles, 1);
      projectFiles[0] := options.ProjectPath;

    end
    else if DirectoryExists(options.ProjectPath) then
    begin
      projectFiles := TArray <string> (TDirectory.GetFiles(options.ProjectPath, '*.dproj'));
      if Length(projectFiles) = 0 then
      begin
        FLogger.Error('No dproj files found in projectPath : ' + options.ProjectPath);
        exit;
      end;
      FLogger.Information('Found ' + IntToStr(Length(projectFiles)) + ' dproj file(s) to install into.');
    end
    else
    begin
      //should never happen when called from the commmand line, but might from the IDE plugin.
      FLogger.Error('The projectPath provided does no exist, no project to install to');
      exit;
    end;

    if options.PackageFile <> '' then
    begin
      if not FileExists(options.PackageFile) then
      begin
        //should never happen if validation is called on the options.
        FLogger.Error('The specified packageFile [' + options.PackageFile + '] does not exist.');
        exit;
      end;
      result := InstallPackageFromFile(cancellationToken, options, TArray <string> (projectFiles), config);
    end
    else
      result := InstallPackageFromId(cancellationToken, options, TArray <string> (projectFiles), config);
  except
    on e : Exception do
    begin
      FLogger.Error(e.Message);
      result := false;
    end;
  end;

end;

function TPackageInstaller.InstallPackageFromFile(const cancellationToken : ICancellationToken; const options : TInstallOptions; const projectFiles : TArray <string> ; const config : IConfiguration) : boolean;
var
  packageIdString : string;
  packageIdentity : IPackageIdentity;
  projectFile : string;
begin
  //get the package into the cache first then just install as normal
  result := FPackageCache.InstallPackageFromFile(options.PackageFile, true);
  if not result then
    exit;

  //get the identity so we can get the compiler version
  packageIdString := ExtractFileName(options.PackageFile);
  packageIdString := ChangeFileExt(packageIdString, '');
  if not TPackageIdentity.TryCreateFromString(FLogger, packageIdString, '', packageIdentity) then
    exit;

  //update options so we can install from the packageid.
  options.PackageFile := '';
  options.PackageId := packageIdentity.Id + '.' + packageIdentity.Version.ToStringNoMeta;
  options.CompilerVersion := packageIdentity.CompilerVersion; //package file is for single compiler version
  options.Platforms := [packageIdentity.Platform]; //package file is for single platform.

  FContext.Reset;
  try
    for projectFile in projectFiles do
    begin
      if cancellationToken.IsCancelled then
        exit;
      result := InstallPackage(cancellationToken, options, projectFile, config) and result;
    end;

  finally
    FContext.Reset; //free up memory as this might be used in the IDE
  end;

end;

function TPackageInstaller.InstallPackageFromId(const cancellationToken : ICancellationToken; const options : TInstallOptions; const projectFiles : TArray <string> ; const config : IConfiguration) : boolean;
var
  projectFile : string;
begin
  result := true;
  FContext.Reset;
  try
    for projectFile in projectFiles do
    begin
      if cancellationToken.IsCancelled then
        exit;
      result := InstallPackage(cancellationToken, options, projectFile, config) and result;
    end;
  finally
    FContext.Reset;
  end;
end;

function TPackageInstaller.Remove(const cancellationToken : ICancellationToken; const options : TUninstallOptions) : boolean;
begin
  result := false;
end;

function TPackageInstaller.Restore(const cancellationToken : ICancellationToken; const options : TRestoreOptions) : Boolean;
var
  projectFiles : TArray<string>;
  projectFile : string;
  config : IConfiguration;
  groupProjReader : IGroupProjectReader;
  projectList : IList<string>;
  i : integer;
  projectRoot : string;
begin
  result := false;
  try
    //commandline would have validated already, but IDE probably not.
    if (not options.Validated) and (not options.Validate(FLogger)) then
      exit
    else if not options.IsValid then
      exit;

    config := FConfigurationManager.LoadConfig(options.ConfigFile);
    if config = nil then //no need to log, config manager will
      exit;

    FPackageCache.Location := config.PackageCacheLocation;
    if not FRepositoryManager.Initialize(config) then
    begin
      FLogger.Error('Unable to initialize the repository manager.');
      exit;
    end;

    if not FRepositoryManager.HasSources then
    begin
      FLogger.Error('No package sources are defined. Use `dpm sources add` command to add a package source.');
      exit;
    end;


    if FileExists(options.ProjectPath) then
    begin
      //TODO : If we are using a groupProj then we shouldn't allow different versions of a package in different projects
      //need to work out how to detect this.

      if ExtractFileExt(options.ProjectPath) = '.groupproj' then
      begin
        groupProjReader := TGroupProjectReader.Create(FLogger);
        if not groupProjReader.LoadGroupProj(options.ProjectPath) then
          exit;

        projectList := TCollections.CreateList <string> ;
        if not groupProjReader.ExtractProjects(projectList) then
          exit;

        //projects in a project group are likely to be relative, so make them full paths
        projectRoot := ExtractFilePath(options.ProjectPath);
        for i := 0 to projectList.Count - 1 do
        begin
          //sysutils.IsRelativePath returns false with paths starting with .\
          if TPathUtils.IsRelativePath(projectList[i]) then
            //TPath.Combine really should do this but it doesn't
            projectList[i] := TPathUtils.CompressRelativePath(projectRoot, projectList[i])
        end;
        projectFiles := projectList.ToArray;
      end
      else
      begin
        SetLength(projectFiles, 1);
        projectFiles[0] := options.ProjectPath;
      end;
    end
    else if DirectoryExists(options.ProjectPath) then
    begin
      //todo : add groupproj support!
      projectFiles := TArray <string> (TDirectory.GetFiles(options.ProjectPath, '*.dproj'));
      if Length(projectFiles) = 0 then
      begin
        FLogger.Error('No project files found in projectPath : ' + options.ProjectPath);
        exit;
      end;
      FLogger.Information('Found ' + IntToStr(Length(projectFiles)) + ' project file(s) to restore.');
    end
    else
    begin
      //should never happen when called from the commmand line, but might from the IDE plugin.
      FLogger.Error('The projectPath provided does no exist, no project to install to');
      exit;
    end;

    result := true;
    //TODO : create some sort of context object here to pass in so we can collect runtime/design time packages
    for projectFile in projectFiles do
    begin
      if cancellationToken.IsCancelled then
        exit;
      result := RestoreProject(cancellationToken, options, projectFile, config) and result;
    end;
  except
    on e : Exception do
    begin
      FLogger.Error(e.Message);
      result := false;
    end;
  end;
end;

function TPackageInstaller.RestoreProject(const cancellationToken : ICancellationToken; const options : TRestoreOptions; const projectFile : string; const config : IConfiguration) : Boolean;
var
  projectEditor : IProjectEditor;
  platforms : TDPMPlatforms;
  platform : TDPMPlatform;
  platformResult : boolean;
  ambiguousProjectVersion : boolean;
  ambiguousVersions : string;
begin
  result := false;

  //make sure we can parse the dproj
  projectEditor := TProjectEditor.Create(FLogger, config, options.CompilerVersion);

  if not projectEditor.LoadProject(projectFile) then
  begin
    FLogger.Error('Unable to load project file, cannot continue');
    exit;
  end;


  if cancellationToken.IsCancelled then
    exit;

  ambiguousProjectVersion := IsAmbigousProjectVersion(projectEditor.ProjectVersion, ambiguousVersions);

  if ambiguousProjectVersion and (options.CompilerVersion = TCompilerVersion.UnknownVersion) then
    FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] is ambiguous (' + ambiguousVersions  +'), recommend specifying compiler version on command line.');

  //if the compiler version was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that version.
  if options.CompilerVersion <> TCompilerVersion.UnknownVersion then
  begin
    if projectEditor.CompilerVersion <> options.CompilerVersion then
    begin
      if not ambiguousProjectVersion then
        FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] does not match the compiler version.');
      projectEditor.CompilerVersion := options.CompilerVersion;
    end;
  end
  else
    options.CompilerVersion := projectEditor.CompilerVersion;

  FLogger.Warning('Restoring for compiler version  [' + CompilerToString(options.CompilerVersion) + '].');


  //if the platform was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that platform.
  if options.Platforms <> [] then
  begin
    platforms := options.Platforms * projectEditor.Platforms; //gets the intersection of the two sets.
    if platforms = [] then //no intersection
    begin
      FLogger.Warning('Skipping project file [' + projectFile + '] as it does not match specified platforms.');
      exit;
    end;
    //TODO : what if only some of the platforms are supported, what should we do?
  end
  else
    platforms := projectEditor.Platforms;

  result := true;
  for platform in platforms do
  begin
    if cancellationToken.IsCancelled then
      exit(false);

    options.Platforms := [platform];
    FLogger.Information('Restoring project [' + projectFile + '] for [' + DPMPlatformToString(platform) + ']', true);
    platformResult := DoRestoreProject(cancellationToken, options, projectFile, projectEditor, platform, config);
    if not platformResult then
      FLogger.Error('Restore failed for ' + DPMPlatformToString(platform))
    else
      FLogger.Success('Restore succeeded for ' + DPMPlatformToString(platform), true);
    result := platformResult and result;
    FLogger.Information('');
  end;
end;

function TPackageInstaller.UnInstall(const cancellationToken: ICancellationToken; const options: TUnInstallOptions): boolean;
var
  projectFiles : TArray<string>;
  projectFile : string;
  config : IConfiguration;
  groupProjReader : IGroupProjectReader;
  projectList : IList<string>;
  i : integer;
  projectRoot : string;
begin
  result := false;
  //commandline would have validated already, but IDE probably not.
  if (not options.Validated) and (not options.Validate(FLogger)) then
    exit
  else if not options.IsValid then
    exit;

  config := FConfigurationManager.LoadConfig(options.ConfigFile);
  if config = nil then //no need to log, config manager will
    exit;

  FPackageCache.Location := config.PackageCacheLocation;
  if not FRepositoryManager.Initialize(config) then
  begin
    FLogger.Error('Unable to initialize the repository manager.');
    exit;
  end;

  if FileExists(options.ProjectPath) then
  begin
    //TODO : If we are using a groupProj then we shouldn't allow different versions of a package in different projects
    //need to work out how to detect this.

    if ExtractFileExt(options.ProjectPath) = '.groupproj' then
    begin
      groupProjReader := TGroupProjectReader.Create(FLogger);
      if not groupProjReader.LoadGroupProj(options.ProjectPath) then
        exit;

      projectList := TCollections.CreateList <string> ;
      if not groupProjReader.ExtractProjects(projectList) then
        exit;

      //projects in a project group are likely to be relative, so make them full paths
      projectRoot := ExtractFilePath(options.ProjectPath);
      for i := 0 to projectList.Count - 1 do
      begin
        //sysutils.IsRelativePath returns false with paths starting with .\
        if TPathUtils.IsRelativePath(projectList[i]) then
          //TPath.Combine really should do this but it doesn't
          projectList[i] := TPathUtils.CompressRelativePath(projectRoot, projectList[i])
      end;
      projectFiles := projectList.ToArray;
    end
    else
    begin
      SetLength(projectFiles, 1);
      projectFiles[0] := options.ProjectPath;
    end;
  end
  else if DirectoryExists(options.ProjectPath) then
  begin
    //todo : add groupproj support!
    projectFiles := TArray <string> (TDirectory.GetFiles(options.ProjectPath, '*.dproj'));
    if Length(projectFiles) = 0 then
    begin
      FLogger.Error('No project files found in projectPath : ' + options.ProjectPath);
      exit;
    end;
    FLogger.Information('Found ' + IntToStr(Length(projectFiles)) + ' project file(s) to uninstall from.');
  end
  else
  begin
    //should never happen when called from the commmand line, but might from the IDE plugin.
    FLogger.Error('The projectPath provided does no exist, no project to install to');
    exit;
  end;


  result := true;
  //TODO : create some sort of context object here to pass in so we can collect runtime/design time packages
  for projectFile in projectFiles do
  begin
    if cancellationToken.IsCancelled then
      exit;
    result := UnInstallFromProject(cancellationToken, options, projectFile, config) and result;
  end;


end;

function TPackageInstaller.UnInstallFromProject(const cancellationToken: ICancellationToken; const options: TUnInstallOptions; const projectFile: string; const config: IConfiguration): Boolean;
var
  projectEditor : IProjectEditor;
  platforms : TDPMPlatforms;
  platform : TDPMPlatform;
  platformResult : boolean;
  ambiguousProjectVersion : boolean;
  ambiguousVersions : string;
begin
  result := false;

  //make sure we can parse the dproj
  projectEditor := TProjectEditor.Create(FLogger, config, options.CompilerVersion);

  if not projectEditor.LoadProject(projectFile) then
  begin
    FLogger.Error('Unable to load project file, cannot continue');
    exit;
  end;


  if cancellationToken.IsCancelled then
    exit;

  ambiguousProjectVersion := IsAmbigousProjectVersion(projectEditor.ProjectVersion, ambiguousVersions);

  if ambiguousProjectVersion and (options.CompilerVersion = TCompilerVersion.UnknownVersion) then
    FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] is ambiguous (' + ambiguousVersions  +'), recommend specifying compiler version on command line.');

  //if the compiler version was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that version.
  if options.CompilerVersion <> TCompilerVersion.UnknownVersion then
  begin
    if projectEditor.CompilerVersion <> options.CompilerVersion then
    begin
      if not ambiguousProjectVersion then
        FLogger.Warning('ProjectVersion [' + projectEditor.ProjectVersion + '] does not match the compiler version.');
      projectEditor.CompilerVersion := options.CompilerVersion;
    end;
  end
  else
    options.CompilerVersion := projectEditor.CompilerVersion;

  FLogger.Warning('Uninstalling for compiler version  [' + CompilerToString(options.CompilerVersion) + '].');


  //if the platform was specified (either on the command like or through a package file)
  //then make sure our dproj is actually for that platform.
  if options.Platforms <> [] then
  begin
    platforms := options.Platforms * projectEditor.Platforms; //gets the intersection of the two sets.
    if platforms = [] then //no intersection
    begin
      FLogger.Warning('Skipping project file [' + projectFile + '] as it does not match specified platforms.');
      exit;
    end;
    //TODO : what if only some of the platforms are supported, what should we do?
  end
  else
    platforms := projectEditor.Platforms;

  result := true;
  for platform in platforms do
  begin
    if cancellationToken.IsCancelled then
      exit(false);

    options.Platforms := [platform];
    FLogger.Information('Uninstalling from project [' + projectFile + '] for [' + DPMPlatformToString(platform) + ']', true);
    platformResult := DoUninstallFromProject(cancellationToken, options, projectFile, projectEditor, platform, config);
    if not platformResult then
      FLogger.Error('Uninstall failed for ' + DPMPlatformToString(platform))
    else
      FLogger.Success('Uninstall succeeded for ' + DPMPlatformToString(platform), true);
    result := platformResult and result;
    FLogger.Information('');
  end;
end;

end.

