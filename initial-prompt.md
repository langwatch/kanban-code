I want you to take all the lessons learned from:

~/Projects/remote/claude-resume 
~/Projects/claude-remote        
~/Projects/remote/git-orchard 
~/Projects/remote/claude-pushover
~/Projects/remote/claude-amphetamine

and build a macos native liquid glass application of a kanban board to fully control claude code, it will be called simply Kanban

there are several, several requirements, try to keep up:

the idea is that this will be a kanban board, where the backlog is filled by a source, or with manually tasks added by you. The source can be for example, tasks assigned
to you via a github project

then, the second column, you will see the claude code instances working, we know they are active because we can keep pooling the session history and/or keeping track of
the tmux sessions associated with that claude session here

while its working, a secondary system tray app is spun up to show at least one claude is doing work, it means we basically do the same as claude-amphetamine here, it has to be a secondary app so amphetamine listens only to it

then, when the claude requires your attention, like because it needs to approve a plan or because it thinks its done, it moves to the third column, and notifies the user with
a push notification (if it needs an api key etc for notifying on phone and more we can keep using pushover, just require their key and done), we can use all the learnings from
claude-pushover here. If we need users to set up claude hooks to make this work we can detect and have an onboarding screen to do it for them automatically

when we first move a task from backlog to in progress, or click a button for claude code to start working on it, we should start a tmux session for it, sending the issue
as the prompt, possibly with a prepended skill name (we use /orchestrate, you can learn how that works from ~/Projects/langwatch-saas/langwatch so you have an idea of our
flow, but it should be configurable for the user), and then a claude inside for that issue name. The new `claude --worktree issue-123` allows it to start claude already
on a worktree of that project, but also a lot of times we just have a manual task, not linked to github, or we just want to kick something off, maybe I kick it from my
terminal directly, in that case we can use `claude --worktree` so it generates it automatically, or maybe I had it open and I asked it in the chat to create this
worktree, so the connection may not be clear

the point is, connecting the worktree with a branch is trivial, git provides it, but connecting a claude session to a worktree is not, we could btw have multiple
sessions for the same worktree, a worktree may not exist for the session (working of main), plus linking a session and worktree to a tmux session may also not be trivial, there might
not be a tmux session for an agent if I started it myself instead of via the Kanban tool. Point is, we will need to think this part really thorougly, we should use the
lessons learned from git-orchard here, but also, we should have a file coordinating all this session-worktree-tmux connections (plain readable json/jsonl file in userland so we can
inspect and debug easily), with a background process and heuristics trying to match (for example, if a claude code is not pointing to a worktree by their session
definition, still I may have started one via the chat with claude, so we should look for any mentions in the conversation that match the branch/worktree git name exactly, in case we don't have
anything assigned to it yet), and it should allow me to change the links manually too for the edge cases (I sometimes switch worktrees within the same session)

from the worktree we can automatically link to a PR on github and learn from git-orchard there. If there is a PR and claude is not actively working on it, then we can move to the next
column, in review. We can automatically pull the pending github comments and CI checks and have a link to open the PR on the browser, if we ask claude to
address anything then it will go back to in progress (per claude-pushover/claude-amphetamine learnings) and as its done it will skip requires attention directly to in review, but it sends notifications etc all the same

once pr is closed/merged, it will move to done, and there will be a button to cleanup worktree

once its cleaned up, it will move to the last column which is All Sessions, there you see all your old sessions, unlinked with any worktrees or tmux sessions or so. You
can hide/show this column, but you can also pick up to start working on it again, by simply sending a message to it it will go to in progress, and by the way, all the
sessions in the board can be forked, or you can move to another checkpoint there, we have a lot to learn from claude-resume here. A session is active even without       
worktree or tmux session attached if its less than a day old (configurable), but I should be able to drag and drop it to the all sessions archive as well if I want to

so as mentioned, the UI will be full native and use apple's new liquid glass design, those columns will be trello/gh projects/etc kanban style columns. Then, on each
session, you should be able to click on them and you will get a full powered native terminal emulator inside (dont know if there is a swiftui/whatever great component
for that already), connected to the tmux session if there is one, but also with the command for me to copy and paste to connect to this tmux session from my own terminal
if I want to.

if there is no tmux session, then we just show the claude code session history (which we should have a tab or somethign to show on the other case anyway, also for
checkpoints etc). Then, if the session has been silent for > 5min, it means there is no activity on it, idk if we can ps aux find if there is a process there by this session id, if there is we probably want to kill it before doing this but, I want that with one button we can claude --resume it here (again lessons learned from claude-resume), which will now put it in a tmux session we can follow, OR, just give me the claude --resume command to run if I want to manage it myself

btw everything must be CRAZY, INSANELY, BLAZING fast, that's the whole idea of going native, and this is why at all points we need to care on not rendering too much
stuff, like I could have too many archived settings so we need like the virtualization there, this background process inspecing history to link active sessions should be
super light, queries to github should be smartly done, terminal emulator should be best-in-class, and so on

lastly but really not least, we should support a fake shell for remote execution with file sync, by getting all the lessons learned from claude-remote. It should be      
configurable the base path vs the remote machine and base path etc for file syncing, shell path replacement etc, and notifications of using local vs remote instance. It  
should start the syncing and the UI should visually display the mutagen status                                                                                            
                                                                                                                                                                        
We can tell users on the readme to install mutagen and tmux for eg if they want to support those things                                                                
                                                                                                                                                                        
now all that that I said is very tighly coupled with claude code, which is fine as this is our expertise. But I want the whole system to be built with adapters so that   
potentially we could readapt the same for gemini cli for example, think about uncle bob practices and code organization                                                   

then, I forgot to mention, but everything will be organized in projects, a project is a folder ofc, so I can have a project pointing to ~/Projects/remote/langwatch-saas/langwatch and another one to ~/Projects/remote/scenario, but, I do also want a view that combines all of them, so I can see all my claude codes running at once, all of my All Sessions of the whole computer. The reasoning is that most of the times I want to see everything for multiple repos, but sometimes I want to focus only in one. Also, sometimes I have a side-project that is totally not related to work, so on this global view I want to be able to exclude which folders I don't want to see there. BTW it can happen too that sometimes I want to start or I have started a claude code in one folder, but its actually operating in another repo, for example when I change work on the same session, but also, a lor of times I start working on ~/Projects/remote/langwatch-saas/langwatch (the subrepo) to actually operate and make changes and PRs to ~/Projects/remote/langwatch-saas, just because /langwatch is where all our /orchestrate and skills and etc are, but the PRs linking worktrees commits etc should be done on saas. I don't think claude-code --worktree can do that, so in this case when picking up we might need to create the worktree by hand, maybe give it a random-words name or something if issue not specified

oh oh, almost forgot something. Claude allows us to name those sessions, the name it automatically gives to it is sometimes horrible, so via the UI we should be able to rename it, and if there is no name, we take lessons learned from claude-resume as well, show the first message sent. And btw, also lesson learned from claude-resume, we should have a bm25 search with the same properties to find any sessions we want wherever, so we can continue working from them, or fork and continue and so on

then, I'm worried of the trade-off of testing, your expertise, iteration speed and performance here. If you tell me we can do everything on swift, perfect, although there is a lot of bashing happening behind the scenes as well where perhaps typescript would be better to control? Typescript with vite as a backend would maybe be faster to compile, test, iterate etc, however I really don't want any performance penalties nor having to deal with bullshit bridge integration time sinkhole, so if you tell me that full modern swift can be as fast and fine for all this, lets go full it. If you think rust is our only salvation for blazing performance here and there, then lets go there too during planing phase, we fear nothing.                                                                                                            
                                                                                
oh another thing, settings will be clearly saved to user folder, like ~/.kanban/settings.json or something easy and cleartext like that, like all modern tools do, and github integration queries etc will be done via the `gh` cli tool, users must have it installed, do an auth login etc, I don't want to fucking deal with oauth right now, just tell users to do it and how to do it as they need in the app, but don't prevent them from using

it if they don't, like the tmux and mutagen, it's all progressive enhancement.
                    
as a general rule users are coders, so for example the settings can have a quick basic editor for their json directly (or open externally), or the gh filters for the source, could be input as a command directly, no fear to open it up for users to just type.
  
but that's it, basically the are building the future, the IDE made for 2026                                                                                                

AGPLv3 license                                                                                                                                                                          
                                                                                                                                                                            
btw, some tmux sessions learning from git-orchard already:                                                                                                                 
                                                                                                                                                                            
⏺ Here's how the git-orchard tmux integration works:

  The Big Picture

  git-orchard is a TUI for managing git worktrees. The tmux piece lets you have a dedicated tmux session per worktree, so each feature branch gets its own terminal environment.

  How It Works

  Setup

  1. You run git-orchard init, which prints a shell wrapper function
  2. You add it to your .zshrc/.bashrc — this creates the orchard command
  3. You always use orchard (not git-orchard directly) — this is critical because Node.js can't cd your shell or attach to tmux sessions on its own

  The IPC Trick (temp file)

  Since a Node process can't control the parent shell, it uses a temp file IPC pattern:

  1. The TUI writes a tmux command to /tmp/git-orchard-tmux-cmd-$uid
  2. The TUI exits
  3. The shell wrapper reads the temp file and evals the command (e.g. tmux new-session or tmux attach)

  Using It

  - From the TUI: Press t on a worktree to create/attach a a tmux session for it
  - From inside tmux: Press Ctrl+B o to open git-orchard as a popup (80% width/height). Pick a worktree and you're switched to that session
  - After detaching: The shell wrapper automatically re-launches orchard, so you're back in the TUI

  Status Bar

  Each tmux session gets a custom status bar showing:
  - Left: Branch name + PR status (e.g. feat/login PR#42 ◉ review)
  - Right: Keybinding hints (^B d detach │ ^B o orchard)

  Session Matching

  When listing worktrees, git-orchard figures out which tmux sessions belong to which worktrees by matching on path, directory name, or branch name. The TUI shows:
  - ▶ tmux:name (green) — session is attached
  - ◼ tmux:name (blue) — session exists but detached

  Cleanup

  When you delete a worktree (d) or do batch cleanup of merged PRs (c), it automatically kills the associated tmux session too                                                                                                                                                
                                                                                                                                                                            
                                                                                                                                                                            
to maximize your token efficiency exploring all that, I want to try something: the commit messages for all those projects are awesome, simple plain text conventional      
commits, so just read their full git log and you will get all the learnings compressed, only explore code for the most tricky parts, or shallowly to understand the        
structure, plus readme ofc                                                                                                                                                 
                                                                                                                                                                            
I will put you in plan mode later, because I think a single plan file can't even capture all that, so as a very first step what I want is for you to create a specs/       
folder under ~/Projects/remote/kanban (fresh new folder, just created), and write ALL the requirements in detailed BDD specs, as user flows, all the requirements and all  
the edge cases that must be tested, splitting into subfolders for organization, imagining already a great open source macos native ui, so also thinking of the files       
that get created to track coordination, settings json files etc
