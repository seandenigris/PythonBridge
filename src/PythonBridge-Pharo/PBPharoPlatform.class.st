Class {
	#name : #PBPharoPlatform,
	#superclass : #PBPlatform,
	#category : #'PythonBridge-Pharo-Platform'
}

{ #category : #hooks }
PBPharoPlatform class >> httpMessageBrokerClass [
	^ PBHttpMessageBroker
]

{ #category : #hooks }
PBPharoPlatform class >> pipenvProcessClass [
	^ PBPharoPipenvProcess
]

{ #category : #accessing }
PBPharoPlatform class >> priority [
	^ 10
]

{ #category : #hooks }
PBPharoPlatform class >> socketMessageBrokerClass [
	^ PBMsgPackPharoBroker
]

{ #category : #private }
PBPharoPlatform class >> uiManagerClass [
	^ PBPharoUiManager
]

{ #category : #hooks }
PBPharoPlatform class >> weakRegistryClass [
	^ PBPharoWeakRegistry
]

{ #category : #private }
PBPharoPlatform >> copyApplicationTo: appFolder application: application [
	"Copy the PythonBridge runtime environment to the specified folder"
	| srcDir cpCommand proc pbSymLink srcFilename dstFilename |

	srcDir := FileLocator imageDirectory / 'PythonBridge'.
	(srcDir exists and: [ srcDir ~= appFolder ]) ifFalse: 
		[ srcDir := self folderForApplication: application ].
	srcDir exists ifFalse: 
		[ self error: 'Unable to locate PythonBridge runtime files' ].

	"Copy the runtime directory"
	srcFilename := srcDir fullName copyReplaceAll: '"' with: '\"'.
	dstFilename := appFolder fullName copyReplaceAll: '"' with: '\"'.
	cpCommand := String streamContents: [ :stream |
		stream
			<< 'cp -a "';
			<< srcFilename;
			<< '" "';
			<< dstFilename;
			<< '"' ].
	proc := OSSUnixSubprocess new 
		shellCommand: cpCommand;
		runAndWait.
	proc isSuccess ifFalse:
		[ self error: 'Unable to install PythonBridge runtime' ].
	"Remove the existing symlink, which probably points to the source folder.
	FileReference>>delete doesn't handle symbolic links, so use the lower layer"
	pbSymLink := (appFolder / 'PythonBridge') resolve.
	pbSymLink exists ifTrue: 
		[ pbSymLink isSymlink 
			ifTrue: [ self removeFile: pbSymLink ]
			ifFalse: [ self error: 'PythonBridge should be a symbolic link' ] ].

]

{ #category : #'private - symlinks' }
PBPharoPlatform >> createSymlinkFor: originalFile on: targetFile [
	OSSUnixSubprocess new
				command: '/bin/ln';
				arguments: (Array 
									with: '-s' 
									with: originalFile asFileReference fullName 
									with: targetFile asFileReference fullName);
				terminateOnShutdown;
				runAndWaitOnExitDo: [ :command | ^ self ].
]

{ #category : #'message broker strategy' }
PBPharoPlatform >> defaultMessageBrokerClass [
	^ self class socketMessageBrokerClass
]

{ #category : #hooks }
PBPharoPlatform >> ensureApplicationDirectory: application [
	| appFolder |

	appFolder := application workingDirectory.
	(appFolder / 'PythonBridge') exists ifTrue: [ ^ self ].
	self copyApplicationTo: appFolder application: application.
	self ensurePBridge: (self folderForApplication: application class baseApplication) symlinkIn: appFolder.
]

{ #category : #private }
PBPharoPlatform >> ensureEnvironmentForApp: anApplication [

	self ensureApplicationDirectory: anApplication.
	self installEnvironmentForApp: anApplication.
]

{ #category : #'private - symlinks' }
PBPharoPlatform >> ensureFolderSymlinkFor: aFolder [
	| symlinkRef |
	symlinkRef := aFolder basename asFileReference.
	symlinkRef exists ifFalse: [ 
		self createSymlinkFor: aFolder on: symlinkRef ]
]

{ #category : #'private - symlinks' }
PBPharoPlatform >> ensurePBridge: pbridgeFolder symlinkIn: aFolder [
	| symlinkRef |
	symlinkRef := aFolder / 'PythonBridge'.
	symlinkRef exists ifFalse: [ 
		self createSymlinkFor: aFolder on: symlinkRef ].
]

{ #category : #utils }
PBPharoPlatform >> folderForApplication: application [
	^ (IceRepository registry 
			detect: [ :each | each includesPackageNamed: application class package name ] 
			ifNone: [ 
				self inform: 'Please add a clone of this project to Iceberg to access to the resources'.
				"For travis!"
				^ '.' asFileReference ]) location
]

{ #category : #utils }
PBPharoPlatform >> forceInstallEnvironmentForApp: application [
	| proc pipenvPath |

	pipenvPath := self pipenvForApplication: application.
	self assert: pipenvPath exists description: 'pipenv is apparently not accessible at a standard location. Please, have a look at the Troubleshooting section of https://objectprofile.github.io/PythonBridge/pages/pharo-installation'.
	proc := OSSUnixSubprocess new
				command: '/bin/bash';
				workingDirectory: application workingDirectory fullName;
				addAllEnvVariablesFromParentWithoutOverride.
	proc
		environmentAt: 'PATH'
		put: pipenvPath parent fullName,
				':', (proc envVariables at: 'PATH').
	proc
		arguments: (Array 
			with: (application workingDirectory / 'install_env.sh') fullName);
		terminateOnShutdown;
		runAndWait.
	proc isSuccess ifFalse: [ self signalPipenvCreateEnvFailed ].
]

{ #category : #utils }
PBPharoPlatform >> installEnvironmentForApp: application [
	| folder |
	folder := application workingDirectory.
	(folder / '.venv') exists ifFalse: [ 
		self forceInstallEnvironmentForApp: application ]
]

{ #category : #hooks }
PBPharoPlatform >> newRandomName [
	^ 'pb' , UUID new asString36
]

{ #category : #accessing }
PBPharoPlatform >> pipenvForApplication: application [
	"Answer the pipenv path for the supplied application"

	^ application settings pipenvPath ifNil:
		[ self class pipenvProcessClass pipenvPath ]
]

{ #category : #'private - symlinks' }
PBPharoPlatform >> removeFile: aFileReference [
	"Use the OS rm command to remove the specified file.
	Required since the file system primitive doesn't seem to handle symbolic links"
	| proc |

	proc := OSSUnixSubprocess new
		command: 'rm';
		arguments: { aFileReference fullName };
		runAndWait.
	proc isSuccess ifFalse: 
		[ self error: 'Unable to remove: ', aFileReference fullName ]
]

{ #category : #accessing }
PBPharoPlatform >> runtimeFolder [
	"Answer the directory where the PythonBridge runtime files are located"

	^ FileLocator imageDirectory / 'PythonBridge'
]

{ #category : #private }
PBPharoPlatform >> signalPipenvCreateEnvFailed [
	"
	Python bridge attempt of creating Pipenv environment failed. To attempt to generate the Pipenv
	environment manually go the project git folder. It may be the PythonBridge, KerasBridge or your
	Bridge, because each of them has a different Pipfile and Pipenv environment.
	
	To remove the current Pipenv environment run in the folder the command: `pipenv --rm`
	To manually create the Pipenv environment run in the folder the command: `bash install_env.sh`
	"
	Error signal: 'Attempt for creating Pipenv environment failed.'
]
