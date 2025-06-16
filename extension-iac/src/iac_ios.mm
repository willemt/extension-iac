#if defined(DM_PLATFORM_IOS)

#include "iac.h"
#include "iac_private.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdlib.h>


struct IAC
{
    IAC()
    {
        Clear();
    }

    void Clear() {
        m_AppDelegate = 0;
        m_Listener = 0;
    }
    dmScript::LuaCallbackInfo*  m_Listener;

    id<UIApplicationDelegate>   m_AppDelegate;

    IACInvocation               m_StoredInvocation;

    IACCommandQueue             m_CmdQueue;
} g_IAC;


@interface IACAppDelegate : NSObject <UIApplicationDelegate>

@end


@implementation IACAppDelegate

-(BOOL) application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation{
    dmLogError("IAC openURL");

    const char* payload = [[url absoluteString] UTF8String];
    const char* origin = sourceApplication ? [sourceApplication UTF8String] : 0;
    IACCommand cmd;
    cmd.m_Command = IAC_INVOKE;
    cmd.m_Payload = strdup(payload);
    cmd.m_Origin = origin ? strdup(origin) : 0;
    IAC_Queue_Push(&g_IAC.m_CmdQueue, &cmd);

    return YES;
}

- (BOOL)application:(UIApplication *)application 
      continueUserActivity:(NSUserActivity *)userActivity 
        restorationHandler:(void (^)(NSArray<id<UIUserActivityRestoring>> * _Nullable))restorationHandler {

    dmLogError("IAC continueUserActivity");

    if ([userActivity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb]) {
        NSURL *url = userActivity.webpageURL;
        // Handle the URL appropriately
        dmLogError("Opened with Universal Link: %@", [url absoluteString]);

        const char* payload = [[url absoluteString] UTF8String];
        if (payload) {
            dmLogError("Opened with Universal Link2: %s", payload);
            IACCommand cmd;
            cmd.m_Command = IAC_INVOKE;
            cmd.m_Payload = strdup(payload);
            cmd.m_Origin = 0;
            IAC_Queue_Create(&g_IAC.m_CmdQueue);
            IAC_Queue_Push(&g_IAC.m_CmdQueue, &cmd);
            // Add your custom handling code here
        } else {
            dmLogError("IAC continueUserActivity no payload");
        }
    }

    return YES;
}

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    dmLogError("IAC willFinishLaunchingWithOptions");

    // Return YES prevents OpenURL from being called, we need to do this as other extensions might and therefore internally handle OpenURL also being called.
    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    dmLogError("IAC didFinishLaunchingWithOptions");

    return YES;
}

@end



struct IACAppDelegateRegister
{
    IACAppDelegateRegister() {
        g_IAC.Clear();
        g_IAC.m_AppDelegate = [[IACAppDelegate alloc] init];
        dmExtension::RegisteriOSUIApplicationDelegate(g_IAC.m_AppDelegate);
    }
    ~IACAppDelegateRegister() {
        dmExtension::UnregisteriOSUIApplicationDelegate(g_IAC.m_AppDelegate);
        [g_IAC.m_AppDelegate release];
        g_IAC.Clear();
    }
};
IACAppDelegateRegister g_IACAppDelegateRegister;


static void OnInvocation(const char* payload, const char *origin)
{
    IAC* iac = &g_IAC;

    lua_State* L = dmScript::GetCallbackLuaContext(iac->m_Listener);
    int top = lua_gettop(L);

    dmLogError("IAC OnInvocation");

    if (!dmScript::SetupCallback(iac->m_Listener))
    {
        dmLogError("IAC OnInvocation: FAILED");
        assert(top == lua_gettop(L));
        return;
    }

    lua_createtable(L, 0, 2);
    lua_pushstring(L, payload);
    lua_setfield(L, -2, "url");
    if (origin) {
        lua_pushstring(L, origin);
        lua_setfield(L, -2, "origin");
    }
    lua_pushnumber(L, DM_IAC_EXTENSION_TYPE_INVOCATION);

    int ret = lua_pcall(L, 3, 0, 0);
    if (ret != 0) {
        dmLogError("Error running iac callback: %s", lua_tostring(L, -1));
        lua_pop(L, 1);
    }

    dmScript::TeardownCallback(iac->m_Listener);
    assert(top == lua_gettop(L));
}


int IAC_PlatformSetListener(lua_State* L)
{
    IAC* iac = &g_IAC;

    dmLogError("IAC IAC_PlatformSetListener");

    if (iac->m_Listener)
        dmScript::DestroyCallback(iac->m_Listener);

    iac->m_Listener = dmScript::CreateCallback(L, 1);

    // handle stored invocation
    const char* payload, *origin;
    if(iac->m_StoredInvocation.Get(&payload, &origin))
        OnInvocation(payload, origin);

    return 0;
}


static void HandleInvocation(const IACCommand* cmd)
{
    if (!g_IAC.m_Listener)
    {
        g_IAC.m_StoredInvocation.Store((const char*)cmd->m_Payload, (const char*)cmd->m_Origin);
    }
    else
    {
        OnInvocation((const char*)cmd->m_Payload, (const char*)cmd->m_Origin);
    }
}


dmExtension::Result AppInitializeIAC(dmExtension::AppParams* params)
{
    dmLogError("IAC AppInitializeIAC");
    IAC_Queue_Create(&g_IAC.m_CmdQueue);
    return dmExtension::RESULT_OK;
}


dmExtension::Result AppFinalizeIAC(dmExtension::AppParams* params)
{
    IAC_Queue_Destroy(&g_IAC.m_CmdQueue);
    return dmExtension::RESULT_OK;
}


dmExtension::Result InitializeIAC(dmExtension::Params* params)
{
    return dmIAC::Initialize(params);
}


dmExtension::Result FinalizeIAC(dmExtension::Params* params)
{
    if (params->m_L == dmScript::GetCallbackLuaContext(g_IAC.m_Listener)) {
        dmScript::DestroyCallback(g_IAC.m_Listener);
        g_IAC.m_Listener = 0;
    }
    return dmIAC::Finalize(params);
}

static void IAC_OnCommand(IACCommand* cmd, void*)
{
    dmLogError("IAC IAC_OnCommand");

    switch (cmd->m_Command)
    {
    case IAC_INVOKE:
        HandleInvocation(cmd);
        break;

    default:
        assert(false);
    }

    free((void*)cmd->m_Payload);
    free((void*)cmd->m_Origin);
}

dmExtension::Result UpdateIAC(dmExtension::Params* params)
{
    IAC_Queue_Flush(&g_IAC.m_CmdQueue, IAC_OnCommand, 0);
    return dmExtension::RESULT_OK;
}


DM_DECLARE_EXTENSION(IACExt, "IAC", AppInitializeIAC, AppFinalizeIAC, InitializeIAC, UpdateIAC, 0, FinalizeIAC)

#endif // DM_PLATFORM_IOS
