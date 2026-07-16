# Issues
This list is not exhaustive
## General
- when interacting with the file selector, if no file is chosen, playlist will be lost and show as 'null'; intermittent
- minimize button does nothing
- closing main view should close whole app even when a subview window is open as well

## Plus! 
## Plus! Slimline
- button cluster at top of skin has click registration offset to the left 

## Plus! Pulsar
- volume/seek sliders drawn when shutter closed
- mute icon is never drawn. 
- viz appears to be affecting the rendering/color space of the sliders drawn over it. 
## Plus! Professional
- slider state is inverted (low volume draws as high volume)
- play, file, fwd, back cluster does not switch between slate and wood, always wood state
- plview left, right, bottom borders have gaps
- windows logo in viz area should disappear shortly after the skin loads. 

## Plus! Plasma Ball
- mouseover is not working for any button cluster
- visualizer does not work
- eq drawn behind main skin, should be drawn in front
- cannot drag files over player to load them

## Plus! Nature
- song timer is not drawn

## Plus! Mecha 
- the default buttons are incorrect, should start as white with black icons and fade to blue with white icons on mouseover. Current state is blue buttons with grey icons. 
- shutter animation is too fast. 

## Plus! Hue Shifter
- the hue shift button does nothing

## Plus! Hard Boiled
- the bottom of the egg is drawn completely black
- plview should be drawn in front of viz. 


## Plus! Bionic Dot
- viz masking is inverted
- There should be a breathing animation when changing colors. 

## Plus! Aquarium
- gems should have a sparkling animation

## Pharoah
- volume slider works but does not redraw
- viz is not masked
- eq button does nothing

## optik
- eq sliders drawn on top of one another
- eye does not animate
- viz does nothing

## Official Xbox MP71
- shutter stuck closed

## Official Xbox XP
- next/prev viz buttons not properly hidden when viz is not active
- when activating viz, the track time is drawn unchanging over the viz
- viz gif not masked properly, should be behind the bezel
- eq button does not work
- gaps in plview left and right borders. 


## New Super Mario Bros
- main view transparency is broken, same for eq transparency
- viz does not work
- pause works but play button does not


## Need for speed underground
- plview and viz resize handles do not work and bottom right corner of window square when should be clipped to graphic shape.
- volume and seek slider behavior is inverted. (when volume is high, it renders as low and vice versa) 

## Navigator
- drawn very small, may need to be scaled up
- close button still works when drawer retracted, resulting in closing app when trying to seek. 

## Nautical
- timer is cut off; 
- play and stop button default state transparency is broken
- transparency does not work when cycling through the different ship themes; yellow background is incorrectly drawn. 
- info, viz, eq buttons are superseded by the vol slider. 


## MSN
- something's transparency is not working correctly resulting in the corner of a red box protruding from behind the skin.
## modernblue
- eq and fullview buttons are drawn twice, once offset.
- no pause button

## Miniplayer
- no track info is drawn

## Military
- close button cluster is drawn twice, once offset. 
- pl view is offset up and to the left of where it should be drawn

## Mechassault
- viz/plview borders have gaps on the left and bottom border
- pause button does not display properly when playing

## Mandalay
- when the music is playing, the play/pause button's background that should be transparent is instead drawn over the skin
- volume slider incorrectly offsets the image left/right.
- eq reset does not work
- viz does not work

## Main\_Street
- most button groups function as a single button

## livin it skate
- pl/eq/viz should have a different view that is currently not drawn at all
- when the pause button is pressed, you need to mouse off the button before you can then hit the play button. 
- color theme button does nothing. 

## Kung Fu Chaos
- track title drawn too low

## Kids
- visualizer does not appear
- volume/seek slides work but do not update

## kenwood\_mp7
- plview: kenwood logo is drawn twice on bottom border
- visualizer control buttons do not properly manage state, and can become disabled after you use them a few times
## josie and the pussycats
- plview only draws the top line and a half or so
- viz is drawn incorrectly - black where it should be drawn, and shows the visualization where it should not be drawn. should be drawn in a Circle
## jaws
- seek slider thumb drawn below where it should be
- onclick buttons are smaller than normal state buttons, therefore we need to not draw the normal state buttons - can keep click detection mask the same;

## israeli
- viz does not work
- eq window not drawn correctly - sliders are all drawn overlapping

## imusica
- The track title does not display

## Ice
- viz and pl windows: borders are not drawn correctly - close button drawn twice and bottom border far too wide; resize handle works but is not visible. 


## holiday\_skin
- viz draws in a box in front of the skin, should have a transparency effect
- after pressing the eq button, eq does not appear and most buttons are broken
- transparency is broken near bottom of the skin.  

## Hob
- media info does not display
- viz does not display
- mute button does not work

## Heart
- plview draws too low, the list is drawn only at the very bottom of the popup

## Harry Potter
- plview and viz view top border missing a section

## Halo 2
- the text for playing track is drawn too low, resulting in it being drawn under halo 2 logo

## Halloween
- (no remaining issues)

## Half Life 2
- when opening skin, the sound plays before the visuals begin to render, not synced
- when the shutter is open, os drop shadow does not work in the top right corner

## Grinch 
- eq reset button nonfunctional
- `kbps` drawn in top left corner of bounding box outside of drawn area
- when eq view is closed, the drop shadow remains

## Gorillaz
- pause button is inoperative
- tracking slider can be moved but will not actually adjust state and snaps back
- when plview is closed, playlist still drawn
- eq sliders do not draw
- eq preset selector inoperative
- the left and right drawers are not properly occluded by the face/helmet graphic

## goo
- volume slider has no visual feedback

## gold
- viz view does not render
- pause button inoperative
- when extending, plview drawer is in foreground, should be behind

## Gnome
- pl text is black on black
- plview does not properly retract
- background renders as mostly transparent

## Ginger\_woman
- pause button inoperative

## Ginger\_man
- (border rendering fixed)

## Gadget
- timer does not render
- next button does not work or register hover

## Frostbite
- eq button inoperative

## erektorset:
- visualizer does not appear
- tracking slider renders but is not interactable
- volume and eq sliders work but update visually only when mousing over the play button cluster

## elvis
- viz button inoperative
- pl view does not retract with the drawer

## ducky
- several button mismaps, most buttons incorrectly mapped.

## Dreamcatcher
- `dreamcatcher` graphic on bottom of pl and viz windows drawn twice: once centered and once left aligned.
- pause button displays as play button on hover and does not pause

## Disney Mix Central
- numerous rendering/alignment issues; it looks like there are multiple views/modes and assets from multiple views are being displayed

## digitaldj
- transparency not working properly resulting in a red box around the skin
- none of the buttons work 
- maybe is just displaying the preview image
- full view requires further investigation; may not be practical to implement outside of windows

## deepbluesomething
- viz is not properly masked
- pl keeps rendering when not in pl view

## darkling
- is it possible to force this to work? party mode

## cyberchannel 
- outline may have some artifacts, does not seem to match the graphics. 
- pl view does not work

## crystal ball
- complex skin, masking not working on viz. 

## Crimson Skies
- skin maybe should have sound effects

## Creed
- doors are drawn on top; should be under main skin element
- pl window is cut off when fully extended i.e. bottom border graphic disappears
- plview does not retract with its drawer. 
- seek slider renders and represents a state but does not do anything
- volume sliders work but do not visually update

## Constantine
- (border rendering fixed)

## Compact
- big black box in front of much of the ui. 

## Combat Flight Simulator
- no play button; cannot play music
- rectangular hole in middle of plview window

## colorchooser
- only the close button and a white box render. unusable

## claw
- eq sliders all drawn on top of each others. 

## Classic
- need to investigate; maybe depends on windows rendering

## Circle
- eq sliders are not drawn.

## Charlies Angels Full Throttle
- pl/preview/gallery button cluster is wired to eq/weblinks/visualizer button cluster. 
- pause button doesn't work

## Cerulean
- right corner of the visualizer exceeds the boundray of the skin; should not be drawn out of that bound.

## Catwoman
- 'catwoman' logo always draws hovered graphic
- pl/viz view borders have gaps on top and right border.
- background graphic in plview with no pl loaded does not tile correctly. 

## CableMusic 
- transparency is not being handled correctly; big holes in the background; probably same error as cyberchannel sking

## Brute Force
- volume and seek sliders do not render correctly
- the button to go back to regular view after going to mini view does not appear. Also after closing shutter, no buttons work

## BlueGrid
- eqview is transparent

## Blue Crush
- visualization button does not make the visualization appear.
- pause button displays as play button on hover and does not pause

## Beck
- volume and seek sliders work but do not visually update. 
- play button does not appear. 

## Batman Begins
- when you press the pause button, the play button appears, but it cannot be used to restart the music
