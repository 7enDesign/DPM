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

unit DPM.IDE.ProjectTreeManager;

//an attempt to hack into the IDE project tree.
//since the IDE does not provide any api to do this
//we are drilling into the IDE internals.. messy.

interface

uses
  System.Rtti,
  Spring.Collections,
  Spring.Container,
  System.Classes,
  Vcl.Controls,
  WinApi.Messages,
  DPM.Core.Options.Search,
  DPM.Core.Project.Interfaces,
  DPM.Core.Configuration.Interfaces,
  DPM.IDE.Logger,
  DPM.IDE.VSTProxy,
  DPM.IDE.ProjectTree.Containers;

type
  TProjectLoadType = (plNone, plSingle, plGroup);

  IDPMProjectTreeManager = interface
  ['{F0BA2907-E337-4591-8E16-FB684AE2E19B}']
    procedure NotifyStartLoading(const mode : TProjectLoadType; const projects : IList<string>);

    procedure NotifyProjectLoaded(const fileName : string);

  end;

const
  WM_PROJECTLOADED = WM_USER + $1234;

type
  TDPMProjectTreeManager = class(TInterfacedObject,IDPMProjectTreeManager)
  private
    FContainer : TContainer;
    FLogger : IDPMIDELogger;

    FWindowHandle : THandle;
    FTimerRunning : boolean;
    FProcessing : boolean;

    FProjectTreeInstance : TControl;
    FVSTProxy : TVirtualStringTreeProxy;
    FSearchOptions : TSearchOptions;

    FProjectLoadList : IQueue<string>;
    FDPMImageIndex : integer;

    FNodeCache : IDictionary<TProjectTreeContainer, PVirtualNode>;

//    procedure DumpInterfaces(AClass: TClass);
  protected
    procedure NotifyProjectLoaded(const fileName : string);
    procedure NotifyStartLoading(const mode: TProjectLoadType; const projects: IList<string>);


    procedure WndProc(var msg: TMessage);

    procedure EnsureProjectTree;

    function TryGetContainerTreeNode(const container : TProjectTreeContainer; out containerNode : PVirtualNode) : boolean;
    procedure AddChildContainer(const parentContainer, childContainer : TProjectTreeContainer);
    procedure AddSiblingContainer(const existingContainer, siblingContainer : TProjectTreeContainer);

    function GetProjects : IList<TProjectTreeContainer>;
    function FindProjectNode(const fileName : string) : TProjectTreeContainer;
    function FindTargetPlatformContainer(const projectContainer : TProjectTreeContainer) : TProjectTreeContainer;
    function FindDPMContainer(const projectContainer : TProjectTreeContainer) : TProjectTreeContainer;

    procedure ConfigureProjectDPMNode(const projectContainer : TProjectTreeContainer; const projectFile : string; const config : IConfiguration);
    procedure UpdateProjectDPMPackages(const targetPlatformsContainer : TProjectTreeContainer; const dpmContainer : TProjectTreeContainer; const projectFile : string; const projectEditor : IProjectEditor);

    procedure DoProjectLoaded(const projectFile : string);

    procedure LoadProjects;

    procedure DoDumpClass(const typ : TRttiInstanceType);
    procedure DumpClass(const obj : TClass);

  public
    constructor Create(const container : TContainer; const logger : IDPMIDELogger);
    destructor Destroy;override;

  end;

implementation

uses
  ToolsApi,
  System.TypInfo,
  System.SysUtils,
  WinApi.Windows,
  Vcl.Graphics,
  Vcl.Forms,
  DPM.Core.Constants,
  DPM.Core.Types,
  DPM.Core.Logging,
  DPM.Core.Options.Common,
  DPM.Core.Configuration.Manager,
  DPM.Core.Project.Editor,
  DPM.IDE.Constants,
  DPM.IDE.Utils;


const
  cCategoryContainerClass = 'Containers.TStdContainerCategory';




{ TProjectTreeManager }

procedure TDPMProjectTreeManager.AddChildContainer(const parentContainer, childContainer: TProjectTreeContainer);
var
  parentNode, childNode : PVirtualNode;
  nodeData : PNodeData;
begin
  if TryGetContainerTreeNode(parentContainer, parentNode) then
  begin
    childNode := FVSTProxy.AddChildNode(parentNode);
    nodeData := FVSTProxy.GetNodeData(childNode);
    nodeData.GraphLocation := childContainer.GraphLocation;
    nodeData.GraphData := childContainer.GraphData;
  end;
end;

procedure TDPMProjectTreeManager.AddSiblingContainer(const existingContainer, siblingContainer: TProjectTreeContainer);
var
  parentNode : PVirtualNode;
  childNode : PVirtualNode;
  nodeData : PNodeData;
begin
  if not TryGetContainerTreeNode(existingContainer, parentNode) then
    raise Exception.Create('Unable to find node for project container');

  childNode := FVSTProxy.InsertNode(parentNode, TVTNodeAttachMode.amInsertAfter);
  nodeData := FVSTProxy.GetNodeData(childNode);
  nodeData.GraphLocation := siblingContainer.GraphLocation;
  nodeData.GraphData := siblingContainer.GraphData;
end;

procedure TDPMProjectTreeManager.ConfigureProjectDPMNode(const projectContainer: TProjectTreeContainer; const projectFile : string; const config : IConfiguration);
var
  dpmContainer : TProjectTreeContainer;
  targetPlatformContainer : TProjectTreeContainer;
  projectEditor : IProjectEditor;

begin
  projectEditor := TProjectEditor.Create(FLogger as ILogger, config);


  targetPlatformContainer := FindTargetPlatformContainer(projectContainer);
  if targetPlatformContainer = nil then
  begin
    FLogger.Debug('targetPlatform container not found for  ' + projectfile);

    exit;
  end;
//  DumpClass(targetPlatformContainer.ClassType);
  //first see if we have allready added dpm to the project
  dpmContainer := FindDPMContainer(projectContainer);
  if dpmContainer = nil then
  begin
    //not found so we need to add it.
    try
      dpmContainer := TProjectTreeContainer.CreateNewContainer(projectContainer, cDPMPackages, cDPMContainer);
      dpmContainer.ImageIndex := FDPMImageIndex;
      targetPlatformContainer := FindTargetPlatformContainer(projectContainer);
      Assert(targetPlatformContainer <> nil);
      //add it to the tree
      AddSiblingContainer(targetPlatformContainer, dpmContainer);

      //this is important.. add it to the model,  without this the dpm node disappears if the IDE rebuilds the tree
      projectContainer.Children.Insert(2, dpmContainer); // 0=build config, 1=target platforms
    except
      on e : Exception do
      begin
        FLogger.Error(e.Message);
        OutputDebugString(PChar(e.Message));
        exit;
      end;
    end;
  end;
  Application.ProcessMessages;
  UpdateProjectDPMPackages(targetPlatformContainer, dpmContainer, projectFile, projectEditor);

end;

constructor TDPMProjectTreeManager.Create(const container : TContainer;const logger : IDPMIDELogger);
begin
  FContainer := container;
  FLogger := logger;
  FProjectLoadList := TCollections.CreateQueue<string>;
  FWindowHandle := AllocateHWnd(WndProc);

  //can't find it here as it's too early as our expert is loaded before the project manager is loaded.
  FProjectTreeInstance := nil;
  FVSTProxy := nil;

  FSearchOptions := TSearchOptions.Create;
  // This ensures that the default config file is uses if a project one doesn't exist.
  FSearchOptions.ApplyCommon(TCommonOptions.Default);


  FNodeCache := TCollections.CreateDictionary<TProjectTreeContainer, PVirtualNode>();

//  SetTimer(FWindowHandle, 1, )

end;

destructor TDPMProjectTreeManager.Destroy;
begin
  FLogger := nil;
  FVSTProxy.Free;
  DeallocateHWnd(FWindowHandle);
  FSearchOptions.Free;
  inherited;
end;

procedure TDPMProjectTreeManager.EnsureProjectTree;
var
  bitmap : TBitmap;
//  ctx : TRttiContext;
//  typ : TRttiInstanceType;
begin
  if FVSTProxy <> nil then
    exit;

//  typ := ctx.FindType('TBasePlatformContainer').AsInstance;
//  DoDumpClass(typ);



 //TODO : control name and class discovered via IDE Explorer https://www.davidghoyle.co.uk/WordPress - need to check it's the same for all supported versions of the IDE
  if FVSTProxy = nil then
  begin
    FProjectTreeInstance := FindIDEControl('TVirtualStringTree', 'ProjectTree2');
    Assert(FProjectTreeInstance <> nil);
    FVSTProxy := TVirtualStringTreeProxy.Create(FProjectTreeInstance, FLogger);
    bitmap := TBitmap.Create;
    try
      bitmap.LoadFromResourceName(HInstance, 'DPMIDELOGO_16');
      FDPMImageIndex := FVSTProxy.Images.AddMasked(bitmap, clFuchsia);
    finally
      bitmap.Free;
    end;
  end;
end;

function TDPMProjectTreeManager.FindDPMContainer(const projectContainer: TProjectTreeContainer): TProjectTreeContainer;
var
  childContainer : TProjectTreeContainer;
  children : IInterfaceList;
  i : integer;
begin
  children := projectContainer.Children;
  for i := 0 to children.Count -1 do
  begin
    childContainer := TProjectTreeContainer(children[i] as TObject);
    if SameText(childContainer.DisplayName, cDPMPackages ) then
      exit(childContainer);
  end;
  result := nil;
end;

function TDPMProjectTreeManager.FindProjectNode(const fileName: string): TProjectTreeContainer;
var
  displayName : string;
  rootNode, projectNode : PVirtualNode;
  nodeData: PNodeData;
  container : TProjectTreeContainer;
  project : ICustomProjectGroupProject;
//  graphLocation : IInterface;
//  graphData : IInterface;
begin
  result := nil;
  displayName := ChangeFileExt(ExtractFileName(fileName),'');

  rootNode := FVSTProxy.GetFirstVisibleNode;
  if Assigned(rootNode) then
  begin
    projectNode := FVSTProxy.GetFirstChild(rootNode);
    while projectNode <> nil do
    begin
      nodeData := FVSTProxy.GetNodeData(projectNode);

      //DumpClass((nodeData.GraphLocation as TObject).ClassType);
      container := TProjectTreeContainer(nodeData.GraphLocation as TObject);
      if Assigned(container) then
      begin
        project := container.Project;
        if project <> nil then
        begin
          if SameText(container.FileName, fileName) then
          begin
//            graphLocation := container.GraphLocation;
//            graphData := container.GraphData;
            //take this opportunity to cache the node.
            FNodeCache[container] := projectNode;
            exit(container);
          end;
        end;
      end;
      projectNode := FVSTProxy.GetNextSibling(projectNode);
    end;
  end;
end;

function TDPMProjectTreeManager.FindTargetPlatformContainer(const projectContainer: TProjectTreeContainer): TProjectTreeContainer;
var
  childContainer : TProjectTreeContainer;
  children : IInterfaceList;
  i : integer;
begin
  result := nil;
  children := projectContainer.Children;
  if children = nil then
  begin
    FLogger.Debug('projectContainer  children Empty for  ' + projectContainer.DisplayName);
    exit;
  end;

  for i := 0 to children.Count -1 do
  begin
    childContainer := TProjectTreeContainer(children[i] as TObject);
    if SameText(childContainer.ClassName, 'TBasePlatformContainer') then //class name comes from rtti inspection
      exit(childContainer);
  end;
end;

function TDPMProjectTreeManager.GetProjects: IList<TProjectTreeContainer>;
var
  rootNode, projectNode: Pointer;
  nodeData: PNodeData;
  proxy : TProjectTreeContainer;
begin
//
  EnsureProjectTree;
  result := TCollections.CreateList<TProjectTreeContainer>();
  rootNode := FVSTProxy.GetFirstVisibleNode;
  if Assigned(rootNode) then
  begin
    projectNode := FVSTProxy.GetFirstChild(rootNode);
    while projectNode <> nil do
    begin
      nodeData := FVSTProxy.GetNodeData(projectNode);
      proxy := TProjectTreeContainer(nodeData.GraphLocation as TObject);
      //FLogger.Debug('Project Container ' + proxy.DisplayName);
      if Assigned(proxy) then
        result.Add(proxy);
      //DumpClass(proxy.ClassType);

      projectNode := FVSTProxy.GetNextSibling(projectNode);
    end;
  end;
end;

procedure TDPMProjectTreeManager.LoadProjects;
var
  projects : IList<TProjectTreeContainer>;
  project : TProjectTreeContainer;
  configurationManager : IConfigurationManager;
  config : IConfiguration;
begin
  //load our dpm configuration
  configurationManager := FContainer.Resolve<IConfigurationManager>;
  config := configurationManager.LoadConfig(FSearchOptions.ConfigFile);

  projects := GetProjects;
  for project in projects do
    ConfigureProjectDPMNode(project, project.DisplayName + '.dproj', config);

end;

procedure TDPMProjectTreeManager.NotifyStartLoading(const mode : TProjectLoadType; const projects : IList<string>);
begin

end;


procedure TDPMProjectTreeManager.NotifyProjectLoaded(const fileName: string);
begin
  //The project tree nodes do not seem to have been added at this stage
  //however if we check again after everything is loaded they are accessible
  //so this just delays things enough for the tree nodes to have been created.

  if FTimerRunning then
    KillTimer(FWindowHandle, 1);

//  MonitorEnter(Self);
//  try
    FProjectLoadList.Enqueue(fileName);
    //restart it.
    //experimentation needed to determine optimum value. 200 is too low, 300 works on the
    //project groups I tested with. Needs more testing.
//    SetTimer(FWindowHandle, 1, 1000, nil);
//    FTimerRunning := true;

// this seemed to work ok with single projects, but with groups
// the message was getting processed before the project tree was constructed fully
    PostMessage(FWindowHandle, WM_PROJECTLOADED, 0,0);
//  finally
//    MonitorExit(Self);
//  end;
end;

function TDPMProjectTreeManager.TryGetContainerTreeNode(const container: TProjectTreeContainer; out containerNode: PVirtualNode): boolean;
var
  node : PVirtualNode;
  nodeData : PNodeData;
begin
  //TODO : need a way to clear the cache.
  containerNode := nil;
  result := false;
  if FNodeCache.TryGetValue(container, containerNode) then
    exit(true);

  node := FVSTProxy.GetFirstNode;
  while node <> nil do
  begin
    nodeData := FVSTProxy.GetNodeData(node);
    if container = (nodeData.GraphLocation as TObject) then
    begin
      containerNode := node;
      FNodeCache[container] := containerNode;
      exit(true);
    end
    else
    begin
      if nodeData.GraphLocation <> nil then
        FNodeCache[TProjectTreeContainer(nodeData.GraphLocation as TObject)] := node;
    end;
    node := FVSTProxy.GetNextNode(node);
  end;
end;

procedure TDPMProjectTreeManager.UpdateProjectDPMPackages(const targetPlatformsContainer : TProjectTreeContainer; const dpmContainer: TProjectTreeContainer; const projectFile : string; const projectEditor : IProjectEditor);
var
  projectGroup : IOTAProjectGroup;
  project : IOTAProject;
  sConfigFile : string;
  pf : TDPMPlatform;
  dpmNode : PVirtualNode;
  dpmChildren : IInterfaceList;

  function FindProject : IOTAProject;
  var
    j : integer;
  begin
    result := nil;
    for j := 0 to projectGroup.ProjectCount -1 do
    begin
      if SameText(projectGroup.Projects[j].FileName, projectFile) then
        exit(projectGroup.Projects[j]);
    end;
  end;

  //TODO: Figure out image indexes for platforms.
  function DPMPlatformImageIndex(const pf : TDPMPlatform) : integer;
  begin
    result := -1;
    case pf of
      TDPMPlatform.UnknownPlatform: ;
      TDPMPlatform.Win32:  result := 90;
      TDPMPlatform.Win64:  result := 91;
      TDPMPlatform.WinArm32: ;
      TDPMPlatform.WinArm64: ;
      TDPMPlatform.OSX32: result := 88;
      TDPMPlatform.OSX64: result := 88;
      TDPMPlatform.AndroidArm32: result := 92;
      TDPMPlatform.AndroidArm64: result := 92;
      TDPMPlatform.AndroidIntel32: ;
      TDPMPlatform.AndroidIntel64: ;
      TDPMPlatform.iOS32: result := 93;
      TDPMPlatform.iOS64: result := 93;
      TDPMPlatform.LinuxIntel32: result := 89;
      TDPMPlatform.LinuxIntel64: result := 89;
      TDPMPlatform.LinuxArm32: ;
      TDPMPlatform.LinuxArm64: ;
    end;
  end;


  procedure AddPlatform(const pf : TDPMPlatform; const PackageReferences : IList<IPackageReference>);
  var
    platformContainer : TProjectTreeContainer;
    packageRef : IPackageReference;
    i : integer;

    procedure AddPackage(const parentContainer : TProjectTreeContainer; const packageReference : IPackageReference; const children : IInterfaceList);
    var
      packageRefContainer : TProjectTreeContainer;
      depRef : IPackageReference;
      j : integer;
    begin
      packageRefContainer := TProjectTreeContainer.CreateNewContainer(parentContainer, packageReference.ToIdVersionString,cDPMContainer);
      packageRefContainer.ImageIndex := -1;
      AddChildContainer(parentContainer, packageRefContainer);
      children.Add(packageRefContainer);

      if packageReference.HasDependencies then
      begin
        packageRefContainer.Children := TInterfaceList.Create;
        for j := 0 to packageReference.Dependencies.Count -1 do
        begin
          depRef := packageReference.Dependencies[j];
          AddPackage(packageRefContainer, depRef, packageRefContainer.Children);
        end;
      end;
    end;

  begin
    platformContainer := TProjectTreeContainer.CreateNewContainer(dpmContainer, DPMPlatformToString(pf),cDPMContainer);
    platformContainer.ImageIndex := DPMPlatformImageIndex(pf);
    AddChildContainer(dpmContainer, platformContainer);
    dpmChildren.Add(platformContainer);

    if PackageReferences.Any then
    begin
      platformContainer.Children := TInterfaceList.Create;

      //using for loop rather the enumerator for per reasons.
      for i := 0 to PackageReferences.Count -1 do
      begin
        packageRef := PackageReferences[i];
        if packageRef.Platform <> pf then
          continue;

        AddPackage(platformContainer, packageRef, platformContainer.Children);

      end;
    end;
  end;


begin
  Assert(dpmContainer <> nil);
  projectGroup := (BorlandIDEServices as IOTAModuleServices).MainProjectGroup;

  //projectGroup.FindProject doesn't work! so we do it ourselves.
  project := FindProject;
  if project = nil then
    exit;

  dpmChildren := dpmContainer.Children;
  //Clear dpm node before doing this
  if dpmChildren <> nil then
  begin
    dpmChildren.Clear;
    if TryGetContainerTreeNode(dpmContainer, dpmNode) then
      FVSTProxy.DeleteChildren(dpmContainer);
  end
  else
  begin
    //the container classes don't create the list, so we must.
    dpmChildren := TInterfaceList.Create;
    dpmContainer.Children := dpmChildren;
  end;

  //if there is a project specific config file then that is what we should use.
  sConfigFile := IncludeTrailingPathDelimiter(ExtractFilePath(project.FileName)) + cDPMConfigFileName;
  if FileExists(sConfigFile) then
    FSearchOptions.ConfigFile := sConfigFile;


  if projectEditor.LoadProject(projectFile) then
  begin

    for pf in projectEditor.Platforms do
    begin
//      FLogger.Debug('Target platform : ' + DPMPlatformToString(pf));
//      Application.ProcessMessages;
      AddPlatform(pf, projectEditor.PackageReferences);
    end;
  end;

end;

procedure TDPMProjectTreeManager.DoDumpClass(const typ: TRttiInstanceType);
var

  Field : TRttiField;

  Prop: TRttiProperty;
  IndexProp : TRttiIndexedProperty;
  intfType : TRttiInterfaceType;

  method : TRttiMethod;
  sMethod : string;

begin
  OutputDebugString(PChar(''));
  OutputDebugString(PChar('class ' + Typ.Name +' = class(' + Typ.MetaclassType.ClassParent.ClassName + ')'));

  for intfType in Typ.GetImplementedInterfaces do
  begin
     OutputDebugString(PChar('  implements interface ' + intfType.Name + ' [' + intfType.GUID.ToString + ']'));

  end;
  OutputDebugString(PChar(''));

  for Field in Typ.GetDeclaredFields do
  begin
    OutputDebugString(PChar('  ' + Field.Name + ' : ' + Field.FieldType.Name));
  end;
  OutputDebugString(PChar(''));

  for Prop in Typ.GetDeclaredProperties do
  begin
    OutputDebugString(PChar('  property ' + Prop.Name + ' : ' + prop.PropertyType.Name));

    if prop.PropertyType is TRttiInterfaceType then
    begin
      intfType := prop.PropertyType as TRttiInterfaceType;

       OutputDebugString(PChar('interface ' + intfType.Name + ' [' + intfType.GUID.ToString + ']'));
    end;
  end;

  for IndexProp in Typ.GetDeclaredIndexedProperties do
  begin
    OutputDebugString(PChar('  property ' + IndexProp.Name  + '[] : ' + IndexProp.PropertyType.Name));
  end;
  OutputDebugString(PChar(''));

  for method in Typ.GetDeclaredMethods do
  begin
    sMethod := method.Name;
    if method.ReturnType <> nil then
      sMethod := '  function ' + sMethod +  ' : ' + method.ReturnType.Name
    else if method.IsConstructor then
      sMethod := '  constructor ' + sMethod
    else if method.IsDestructor then
      sMethod := '  destructor ' + sMethod
    else
      sMethod := '  procedure ' + sMethod;

    OutputDebugString(PChar(sMethod));
  end;

end;

procedure TDPMProjectTreeManager.DoProjectLoaded(const projectFile : string);
var
  projectContainer : TProjectTreeContainer;
  configurationManager : IConfigurationManager;
  config : IConfiguration;
begin
  //load our dpm configuration
  configurationManager := FContainer.Resolve<IConfigurationManager>;
  config := configurationManager.LoadConfig(FSearchOptions.ConfigFile);

  EnsureProjectTree;
  projectContainer := FindProjectNode(projectFile);

  if projectContainer <> nil then
    ConfigureProjectDPMNode(projectContainer, projectFile, config)
  else
    FLogger.Debug('project container not found for ' + projectfile);

end;

procedure TDPMProjectTreeManager.DumpClass(const obj: TClass);
var
  Ctx: TRttiContext;
  typ : TRttiInstanceType;
begin
  if not (obj.ClassParent = TObject) then
    DumpClass(obj.ClassParent);

  Typ := Ctx.GetType(obj).AsInstance;
  DoDumpClass(typ);

end;

//procedure TDPMProjectTreeManager.DumpInterfaces(AClass: TClass);
//var
//  i : integer;
//  InterfaceTable: PInterfaceTable;
//  InterfaceEntry: PInterfaceEntry;
//begin
//  while Assigned(AClass) do
//  begin
//    InterfaceTable := AClass.GetInterfaceTable;
//    if Assigned(InterfaceTable) then
//    begin
//      OutputDebugString(PChar('Implemented interfaces in ' +  AClass.ClassName));
//      for i := 0 to InterfaceTable.EntryCount-1 do
//      begin
//        InterfaceEntry := @InterfaceTable.Entries[i];
//
//        OutputDebugString(PChar(Format('%d. GUID = %s offest = %s',[i, GUIDToString(InterfaceEntry.IID), IntToHex(InterfaceEntry.IOffset,2)])));
//      end;
//    end;
//    AClass := AClass.ClassParent;
//  end;
//  writeln;
//end;

procedure TDPMProjectTreeManager.WndProc(var msg: TMessage);
var
  project : string;
begin
  case msg.Msg of
    WM_PROJECTLOADED :
    begin
      if FTimerRunning then
      begin
        KillTimer(FWindowHandle, 1);
        FTimerRunning := false;
      end;
      SetTimer(FWindowHandle, 1, 2000, nil);
      FTimerRunning := true;
      msg.Result := 1;
    end;
    WM_TIMER :
    begin
      //stop the timer.
      FTimerRunning := false;
      KillTimer(FWindowHandle, 1);
//      MonitorEnter(Self);
      try
        FProcessing := true;
        EnsureProjectTree;
        FVSTProxy.BeginUpdate;
        try
          while FProjectLoadList.TryDequeue(project) do
          begin
            DoProjectLoaded(project);
          end;
        finally
          FVSTProxy.EndUpdate;
        end;
      finally
        FProcessing := false;
//        MonitorExit(Self);
      end;
      msg.Result := 1;
    end
  else
    Msg.Result := DefWindowProc(FWindowHandle, Msg.Msg, Msg.wParam, Msg.lParam);
  end;
end;


end.