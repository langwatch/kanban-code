Feature: Any file attached to a chat message
  As a human sending work to an agent
  I want to attach a video, a PDF, a zip or any other file to a message
  So that the agent can open it, not only the images it sees inline

  Images keep going inline to the assistant. Every other file is copied to the
  machine where the card's assistant runs, and the message carries one line per
  file, "[File: /absolute/path]", which the assistant reads like any path.

  Background:
    Given a card with a live session

  Scenario: Drop a video on the Main chat
    Given the card shows its chat view
    When I drop "demo.mp4" on the card
    Then a chip with a film icon, "demo.mp4" and its size shows in the composer
    And the chip shows the upload progress until the file is on the machine of the assistant
    And send waits until the upload is done
    When I send "what is wrong in this recording?"
    Then the agent gets the text followed by "[File: <path>/demo.mp4]"
    And the sent message shows the text with a "demo.mp4" chip, not the raw line

  Scenario: Drop a file on an open conversation
    Given a conversation of the card is open
    When I drop "spec.pdf" on the card
    Then the chip shows in that conversation's composer, not in Main's

  Scenario: Attach with the paperclip or a paste
    When I press the paperclip in the composer and pick "logs.zip"
    Or I copy "logs.zip" in Finder and paste it in the composer
    Then "logs.zip" attaches as a file
    And a copied image file still pastes as an inline image

  Scenario: Drop a file on the terminal
    Given the card shows its terminal
    When I drop "notes.txt" on the card
    Then the file goes to the machine of the assistant and its path is typed in the terminal

  Scenario: A card another master owns
    Given the card is owned by the box
    When I attach "demo.mp4" on the Mac or on the phone
    Then the file is sent in chunks of 8 MiB to POST /v1/cards/{id}/files on the box
    And it lands in ~/.kanban-code/files/<upload>/demo.mp4 on the box, with its original name
    And the prompt names that path on the box

  Scenario: A card whose session runs on a machine the master drives
    Given the card's session runs on a boxd or ssh machine
    When I attach "demo.mp4"
    Then the file is copied to ~/.kanban-code/files/<upload>/demo.mp4 on that machine

  Scenario: A file over the limit
    When I attach a file over 2 GB
    Then the chip says it is over the 2 GB limit and nothing is uploaded
    And a file over 512 MB for a boxd or ssh machine is refused with that limit named

  Scenario: The phone attaches any file
    Given the iPhone app on a master that lists the "files" feature
    When I pick "Choose File" in the + menu and pick "report.pdf"
    Then it uploads with progress and the message carries its "[File: ...]" line

  Scenario: The CLI sends a file
    When I run "kanban remote send <card> 'look at this' --file demo.mp4"
    Then the file is uploaded to the master that owns the card
    And the prompt carries "[File: <path on that master>/demo.mp4]"

  Scenario: A failed send keeps the files
    Given a message with a file failed to reach the session
    When I retry or edit it
    Then its "[File: ...]" lines are still in the text, as the prompt journal kept them
