# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51
#
# Author: Tim Fischer <fischeti@iis.ee.ethz.ch>


import matplotlib.pyplot as plt

PULPRed             = '#A8322C'
PULPRedLight        = '#A8322CC8'
PULPRedVeryLight    = '#A8322C96'
PULPBlue            = '#1269B0'
PULPBlueLight       = '#1269B0C8'
PULPBlueVeryLight   = '#1269B096'
PULPGreen           = '#168638'
PULPGreenLight      = '#168638C8'
PULPGreenVeryLight  = '#16863896'
PULPOrange          = '#F29545'
PULPOrangeLight     = '#F29545C8'
PULPOrangeVeryLight = '#F2954596'
PULPPurple          = '#910569'
PULPPurpleLight     = '#910569C8'
PULPPurpleVeryLight = '#91056996'
PULPOlive           = '#48592C'
PULPOliveLight      = '#48592CC8'
PULPOliveVeryLight  = '#48592C96'
PULPMarine          = '#007996'
PULPMarineLight     = '#007996C8'
PULPMarineVeryLight = '#00799696'
PULPGray            = '#ABABAB'
PULPGrayLight       = '#ABABABC8'
PULPGrayVeryLight   = '#ABABAB96'

colors = [PULPRed, PULPBlue, PULPGreen, PULPOrange, PULPPurple]
light_colors = [PULPRedLight, PULPBlueLight, PULPGreenLight, PULPOrangeLight, PULPPurpleLight]
very_light_colors = [PULPRedVeryLight, PULPBlueVeryLight, PULPGreenVeryLight, PULPOrangeVeryLight, PULPPurpleVeryLight]

plt.rcParams["font.family"] = "CMU Sans Serif"
plt.rcParams["font.size"] = 12
